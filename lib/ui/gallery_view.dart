import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import 'face_refresh.dart';
import 'fast_thumb.dart';
import 'glass.dart';
import 'glass_dock.dart';
import 'media_actions.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'widgets.dart';

const _pageSize = 120;
const _gap = 2.0;

sealed class _Row {}

class _Header extends _Row {
  _Header(this.day, this.start, this.count);

  final DateTime day;
  final int start;
  final int count;
}

class _Photos extends _Row {
  _Photos(this.start, this.count);

  final int start;
  final int count;
}

/// Where a [GalleryView] gets its photos, newest first.
abstract class GallerySource {
  /// A phone album (or "All photos").
  factory GallerySource.album(Future<AssetPathEntity?> Function() load) =
      _AlbumSource;

  /// A list of photo ids, e.g. from a category.
  factory GallerySource.ids(Future<List<String>> Function() load) = _IdSource;

  Future<int> open();
  Future<List<AssetEntity>> page(int start, int size);
}

class _AlbumSource implements GallerySource {
  _AlbumSource(this._load);

  final Future<AssetPathEntity?> Function() _load;
  AssetPathEntity? _path;

  @override
  Future<int> open() async {
    _path = await _load();
    return _path == null ? 0 : _path!.assetCountAsync;
  }

  @override
  Future<List<AssetEntity>> page(int start, int size) async =>
      // By range, not page number: once photos are deleted, start is no
      // longer a whole number of pages and a page number would repeat some.
      _path!.getAssetListRange(start: start, end: start + size);
}

class _IdSource implements GallerySource {
  _IdSource(this._load);

  final Future<List<String>> Function() _load;
  List<String> _ids = const [];

  @override
  Future<int> open() async {
    _ids = await _load();
    return _ids.length;
  }

  @override
  Future<List<AssetEntity>> page(int start, int size) async {
    // Looked up together; photos deleted since scanning are skipped.
    final found = await Future.wait([for (final id in _ids.skip(start).take(size)) AssetThumb.entity(id)]);
    return [for (final a in found) ?a];
  }
}

/// Photos and videos newest first, under a header for each day. Loads more
/// as you scroll; nothing is copied, it reads the library directly.
/// Press and hold (then drag) to select; the bar that appears sends,
/// shares, favourites, files into albums or deletes.
class GalleryView extends StatefulWidget {
  const GalleryView({
    super.key,
    required this.controller,
    required this.source,
    this.emptyMessage = 'No photos here.',
    this.onPicked,
    this.onSelectingChanged,
  });

  final ScanController controller;
  final GallerySource source;
  final String emptyMessage;

  /// Pick mode: taps select, and the bar's button hands back the ids.
  final ValueChanged<List<String>>? onPicked;

  /// Selection mode started or ended, so the page can make way for the
  /// selection bar.
  final ValueChanged<bool>? onSelectingChanged;

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

/// Column counts you can pinch between; the widest ones group by month.
const _levels = [2, 3, 4, 6, 9];
const _defaultLevel = 2;
const _monthFrom = 6;
const _headerHeight = 48.0;

/// The zoom you last pinched to, kept when the dates or the album change.
int _lastLevel = _defaultLevel;

class _GalleryViewState extends State<GalleryView> with SingleTickerProviderStateMixin {
  final List<AssetEntity> _assets = [];
  int _requested = 0;
  int _total = 0;
  bool _ready = false;

  final _scroll = ScrollController();
  int _level = _lastLevel;

  // Two-finger pinch (a Listener, so it never fights scrolling). The grid
  // follows the fingers live, then settles into the new column count.
  final Map<int, Offset> _pointers = {};
  double? _pinchStart;
  bool _pinching = false;
  Offset _focal = Offset.zero;
  final _pinchScale = ValueNotifier<double>(1);
  late final AnimationController _settle = AnimationController(vsync: this, duration: 300.ms)
    ..addListener(() => _pinchScale.value =
        _settleFrom + (1 - _settleFrom) * Curves.easeOutCubic.transform(_settle.value));
  double _settleFrom = 1;

  /// Selected asset ids; selecting mode while not empty.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty || widget.onPicked != null;

  // Drag-to-select: the tile it started on, and the selection before it.
  int? _dragAnchor;
  bool _dragAdding = true;
  Set<String> _dragBase = {};
  bool _busy = false;

  // Layout of the last build, to find the tile under a finger.
  List<_Row> _layoutRows = const [];
  List<double> _layoutOffsets = const [0];
  double _layoutTile = 0;
  double _layoutHeight = 0;

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void dispose() {
    DockVisibility.show(this);
    // After this frame: the tree is locked while widgets are disposed.
    final changed = widget.onSelectingChanged;
    if (_barShown && changed != null) Future.microtask(() => changed(false));
    _settle.dispose();
    _pinchScale.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Whether the selection bar was showing at the last build.
  bool _barShown = false;

  /// The dock (and the page's own bar) make way for the selection bar.
  void _syncDock() {
    final shown = _selected.isNotEmpty && widget.onPicked == null;
    if (shown == _barShown) return;
    _barShown = shown;
    shown ? DockVisibility.hide(this) : DockVisibility.show(this);
    widget.onSelectingChanged?.call(shown);
  }

  int get _columns => _levels[_level];
  bool get _byMonth => _columns >= _monthFrom;

  double _span() {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  Offset _mid() {
    final p = _pointers.values.toList();
    return (p[0] + p[1]) / 2;
  }

  void _pointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 2) {
      _settle.stop();
      _pinchStart = _span();
      _focal = _mid();
      _pinchScale.value = 1;
      // Hold the list still while two fingers are down.
      setState(() => _pinching = true);
    }
  }

  void _pointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    final start = _pinchStart;
    if (_pointers.length != 2 || start == null || start == 0) return;
    var ratio = _span() / start;
    // Rubber-band when there's no further level in that direction.
    if (ratio > 1 && _level == 0) ratio = 1 + (ratio - 1) * 0.2;
    if (ratio < 1 && _level == _levels.length - 1) ratio = 1 - (1 - ratio) * 0.2;
    _pinchScale.value = ratio.clamp(0.45, 2.2);
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length >= 2 || _pinchStart == null) return;
    _pinchStart = null;
    final r = _pinchScale.value;
    // Spread fingers = bigger photos (fewer columns), pinch = more.
    var delta = 0;
    if (r > 1.15) delta = r > 1.75 ? -2 : -1;
    if (r < 0.87) delta = r < 0.58 ? 2 : 1;
    final next = (_level + delta).clamp(0, _levels.length - 1);
    if (next == _level) {
      _animateScale(from: r);
      setState(() => _pinching = false);
      return;
    }
    Haptics.tick();
    // Keep the photo under the fingers under the fingers.
    final anchor = _indexAt(_focal);
    final oldColumns = _columns;
    setState(() {
      _level = _lastLevel = next;
      _pinching = false;
    });
    // The new grid starts at the size the fingers left the old one at.
    _animateScale(from: r * _columns / oldColumns);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToKeep(anchor));
  }

  void _animateScale({required double from}) {
    _settleFrom = from;
    _pinchScale.value = from;
    _settle.forward(from: 0);
  }

  /// After the columns change, scroll so [index]'s row sits where the
  /// fingers were.
  void _scrollToKeep(int? index) {
    if (!_scroll.hasClients || index == null) return;
    final rows = _layoutRows;
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      if (row is _Photos && index >= row.start && index < row.start + row.count) {
        final top = _layoutOffsets[r] + MediaQuery.paddingOf(context).top;
        final target = top + _layoutTile / 2 - _focal.dy;
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
        return;
      }
    }
  }

  bool _sameGroup(DateTime a, DateTime b) => _byMonth
      ? a.year == b.year && a.month == b.month
      : a.year == b.year && a.month == b.month && a.day == b.day;

  /// Bumped by every reset, so a page still loading from before it is
  /// dropped instead of landing in the fresh list as duplicates.
  int _generation = 0;

  Future<void> _reset() async {
    final gen = ++_generation;
    final total = await widget.source.open();
    if (!mounted || gen != _generation) return;
    setState(() {
      _total = total;
      _assets.clear();
      _requested = 0;
      _ready = true;
    });
    _loading = null;
    await _loadMore();
  }

  /// The page being loaded, if any; callers share it.
  Future<void>? _loading;

  Future<void> _loadMore() => _loading ??= _loadPage().whenComplete(() => _loading = null);

  Future<void> _loadPage() async {
    if (_requested >= _total) return;
    final gen = _generation;
    final start = _requested;
    final page = await widget.source.page(start, _pageSize);
    if (!mounted || gen != _generation) return;
    _requested = start + _pageSize;
    AssetThumb.remember(page);
    setState(() => _assets.addAll(page));
  }

  /// Headers (per day, or per month when zoomed out) followed by rows.
  List<_Row> _rows(int columns) {
    final rows = <_Row>[];
    var i = 0;
    while (i < _assets.length) {
      final d = _assets[i].createDateTime;
      final day = DateTime(d.year, d.month, d.day);
      var end = i;
      while (end < _assets.length && _sameGroup(_assets[end].createDateTime, d)) {
        end++;
      }
      rows.add(_Header(day, i, end - i));
      for (var r = i; r < end; r += columns) {
        rows.add(_Photos(r, (end - r).clamp(0, columns)));
      }
      i = end;
    }
    return rows;
  }

  void _open(int index) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        transitionDuration: 300.ms,
        reverseTransitionDuration: 300.ms,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(
            ids: [for (final a in _assets) a.id],
            initial: index,
            controller: widget.controller,
            onRemoved: _dropIds,
            onChanged: _refreshIds,
          ),
        ),
      ),
    );
  }

  // ---- Selection ----

  void _toggle(int index) {
    final id = _assets[index].id;
    Haptics.tick();
    setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
  }

  void _clearSelection() => setState(_selected.clear);

  void _selectDay(int start, int count) {
    Haptics.tick();
    final ids = [for (var i = start; i < start + count && i < _assets.length; i++) _assets[i].id];
    setState(() => ids.every(_selected.contains) ? _selected.removeAll(ids) : _selected.addAll(ids));
  }

  Future<void> _selectAll() async {
    Haptics.tick();
    if (_selected.length >= _total) {
      _clearSelection();
      return;
    }
    // Everything, not just what's been scrolled to.
    while (_requested < _total && mounted) {
      await _loadMore();
    }
    if (mounted) setState(() => _selected.addAll(_assets.map((a) => a.id)));
  }

  /// The asset index under [local] (a point in the grid's box), if any.
  int? _indexAt(Offset local) {
    final rows = _layoutRows;
    if (rows.isEmpty || !_scroll.hasClients) return null;
    final y = local.dy + _scroll.offset - MediaQuery.paddingOf(context).top;
    var lo = 0, hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_layoutOffsets[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final row = rows[lo];
    if (row is! _Photos) return null;
    final col = (local.dx / (_layoutTile + _gap)).floor();
    if (col < 0 || col >= row.count) return null;
    return row.start + col;
  }

  void _dragStart(LongPressStartDetails d) {
    if (_pinching || _pointers.length > 1) return;
    final i = _indexAt(d.localPosition);
    if (i == null) return;
    Haptics.lift();
    _dragAnchor = i;
    _dragBase = Set.of(_selected);
    _dragAdding = !_selected.contains(_assets[i].id);
    _dragTo(i);
  }

  void _dragMove(LongPressMoveUpdateDetails d) {
    if (_dragAnchor == null) return;
    // Scroll along when the finger nears the top or bottom edge.
    final pad = MediaQuery.paddingOf(context);
    if (d.localPosition.dy < pad.top + 60) {
      _scroll.jumpTo((_scroll.offset - 18).clamp(0.0, _scroll.position.maxScrollExtent));
    } else if (d.localPosition.dy > _layoutHeight - pad.bottom - 90) {
      _scroll.jumpTo((_scroll.offset + 18).clamp(0.0, _scroll.position.maxScrollExtent));
    }
    final i = _indexAt(d.localPosition);
    if (i != null) _dragTo(i);
  }

  void _dragTo(int i) {
    final a = _dragAnchor!;
    final range = [for (var k = a < i ? a : i; k <= (a < i ? i : a); k++) _assets[k].id];
    final next = Set.of(_dragBase);
    _dragAdding ? next.addAll(range) : next.removeAll(range);
    if (next.length != _selected.length) Haptics.tick();
    setState(() {
      _selected
        ..clear()
        ..addAll(next);
    });
  }

  void _dragEnd() => _dragAnchor = null;

  List<AssetEntity> get _selectedAssets => [for (final a in _assets) if (_selected.contains(a.id)) a];

  void _dropIds(Set<String> ids) {
    if (ids.isEmpty || !mounted) return;
    setState(() {
      _assets.removeWhere((a) => ids.contains(a.id));
      _selected.removeAll(ids);
      _total -= ids.length;
      _requested -= ids.length;
    });
  }

  /// Picks up changes (like favourites) made elsewhere.
  Future<void> _refreshIds(Set<String> ids) async {
    for (var i = 0; i < _assets.length; i++) {
      if (!ids.contains(_assets[i].id)) continue;
      final fresh = await AssetThumb.entity(_assets[i].id);
      if (fresh != null) _assets[i] = fresh;
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function(MediaActions a, List<AssetEntity> sel) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action(MediaActions(context, widget.controller), _selectedAssets);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _selectionBars(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    // Over the page's own top bar when the grid runs underneath it (that
    // bar steps aside), else at the top of the grid.
    final top = widget.onSelectingChanged != null ? MediaQuery.viewPaddingOf(context).top : pad.top;
    final sel = _selectedAssets;
    final allFav = sel.isNotEmpty && sel.every((a) => a.isFavorite);
    return Stack(children: [
      Positioned(
        top: top + 6,
        left: 12,
        right: 12,
        child: Glass(
          radius: 26,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(children: [
            IconButton(
              tooltip: 'Done',
              onPressed: widget.onPicked != null ? () => Navigator.maybePop(context) : _clearSelection,
              icon: const Icon(Icons.close_rounded),
            ),
            Expanded(
              child: Text('${_selected.length} selected',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: _selectAll,
              child: Text(_selected.length >= _total ? 'Select none' : 'Select all'),
            ),
          ]),
        ).animate().fadeIn(duration: 180.ms).moveY(begin: -16, curve: Curves.easeOutCubic),
      ),
      if (widget.onPicked != null)
        Positioned(
          left: 24,
          right: 24,
          bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            onPressed: _selected.isEmpty
                ? null
                : () => widget.onPicked!([for (final a in _assets) if (_selected.contains(a.id)) a.id]),
            icon: const Icon(Icons.add_rounded),
            label: Text(_selected.isEmpty ? 'Tap photos to pick' : 'Add ${_selected.length}'),
          ).animate().fadeIn().moveY(begin: 30, curve: Curves.easeOutBack),
        )
      else
      Positioned(
        left: 12,
        right: 12,
        bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
        child: MediaActionBar(
          favourite: allFav,
          onSend: _busy ? null : () => _run((a, sel) => a.send(sel)),
          onShare: _busy ? null : () => _run((a, sel) => a.share(sel)),
          onFavourite: _busy
              ? null
              : () => _run((a, sel) async {
                    if (await a.toggleFavourite(sel) != null) await _refreshIds(sel.map((e) => e.id).toSet());
                  }),
          onAlbum: _busy
              ? null
              : () => _run((a, sel) async {
                    final moved = await a.addToAlbum(sel);
                    _clearSelection();
                    if (moved) await _reset();
                  }),
          onTrash: _busy
              ? null
              : () => _run((a, sel) async {
                    if (!await a.confirmTrash(sel.length)) return;
                    _dropIds(await a.trash(sel));
                  }),
        ).animate().fadeIn(duration: 200.ms).moveY(begin: 40, curve: Curves.easeOutBack),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if ((_selected.isNotEmpty && widget.onPicked == null) != _barShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncDock();
      });
    }
    return AnimatedSwitcher(
      duration: 250.ms,
      child: !_ready
          ? PhotosSkeleton(key: const ValueKey('loading'), columns: _columns)
          : _total == 0
              ? EmptyIllustration(key: const ValueKey('empty'), message: widget.emptyMessage)
              : KeyedSubtree(key: const ValueKey('grid'), child: _grid(context)),
    );
  }

  Widget _grid(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return LayoutBuilder(builder: (context, box) {
      final columns = _columns;
      final tile = (box.maxWidth - (columns - 1) * _gap) / columns;
      final rows = _rows(columns);
      final more = _requested < _total;
      final extents = [
        for (final r in rows) r is _Header ? _headerHeight : tile + _gap,
        if (more) 72.0,
      ];
      // Start offset of every row, for the date scrubber's label.
      final offsets = <double>[0];
      for (final e in extents) {
        offsets.add(offsets.last + e);
      }
      _layoutRows = rows;
      _layoutOffsets = offsets;
      _layoutTile = tile;
      _layoutHeight = box.maxHeight;
      final topPad = MediaQuery.paddingOf(context).top;
      String labelAt(double scrollOffset) {
        if (rows.isEmpty) return '';
        // Rows start below the glass bar's padding.
        final offset = scrollOffset - topPad;
        var lo = 0, hi = rows.length - 1;
        while (lo < hi) {
          final mid = (lo + hi + 1) ~/ 2;
          if (offsets[mid] <= offset) {
            lo = mid;
          } else {
            hi = mid - 1;
          }
        }
        for (var r = lo; r >= 0; r--) {
          final row = rows[r];
          if (row is _Header) {
            return _byMonth ? formatShortMonth(row.day) : formatDay(row.day);
          }
        }
        return '';
      }

      final px = FastThumb.step(tile * MediaQuery.devicePixelRatioOf(context));
      FastThumb.gridStep = px;
      final grid = CustomScrollView(
        controller: _scroll,
        physics: _pinching ? const NeverScrollableScrollPhysics() : null,
        slivers: [
          SliverPadding(padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top)),
          SliverVariedExtentList.builder(
            itemCount: extents.length,
            itemExtentBuilder: (i, _) => i < extents.length ? extents[i] : null,
            itemBuilder: (context, r) {
              if (r >= rows.length) {
                _loadMore();
                return const Center(child: CircularProgressIndicator());
              }
              // Start fetching the next page a little before the end.
              if (more && r > rows.length - 8) _loadMore();
              return switch (rows[r]) {
                _Header(:final day, :final start, :final count) => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 6),
                    child: Row(children: [
                      Text(_byMonth ? formatMonth(day) : formatSectionDay(day),
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                      const Spacer(),
                      if (_selecting)
                        _DayCheck(
                          all: [for (var i = start; i < start + count && i < _assets.length; i++) _assets[i].id]
                              .every(_selected.contains),
                          onTap: () => _selectDay(start, count),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text('$count',
                              style: text.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        ),
                    ]),
                  ),
                _Photos(:final start, :final count) => Padding(
                    padding: const EdgeInsets.only(bottom: _gap),
                    child: Row(children: [
                      for (var k = 0; k < count; k++) ...[
                        if (k > 0) const SizedBox(width: _gap),
                        SizedBox.square(
                          dimension: tile,
                          child: _Tile(
                            asset: _assets[start + k],
                            px: px,
                            small: columns >= _monthFrom,
                            selecting: _selecting,
                            selected: _selected.contains(_assets[start + k].id),
                            onTap: () => _selecting ? _toggle(start + k) : _open(start + k),
                          ),
                        ),
                      ],
                    ]),
                  ),
              };
            },
          ),
          SliverPadding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 16)),
        ],
      );
      // The grid scales around the fingers while pinching (only this
      // transform rebuilds, not the tiles).
      final focal = Alignment(
        box.maxWidth == 0 ? 0 : (_focal.dx / box.maxWidth) * 2 - 1,
        box.maxHeight == 0 ? 0 : (_focal.dy / box.maxHeight) * 2 - 1,
      );
      final zoomable = ValueListenableBuilder<double>(
        valueListenable: _pinchScale,
        child: RepaintBoundary(child: grid),
        builder: (context, s, child) => s == 1
            ? child!
            : Transform.scale(scale: s, alignment: focal, filterQuality: FilterQuality.low, child: child),
      );

      return PopScope(
        canPop: _selected.isEmpty || widget.onPicked != null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _clearSelection();
        },
        child: Listener(
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          child: Stack(children: [
            GestureDetector(
              onLongPressStart: _dragStart,
              onLongPressMoveUpdate: _dragMove,
              onLongPressEnd: (_) => _dragEnd(),
              onLongPressCancel: _dragEnd,
              child: ClipRect(child: FaceRefresh(onRefresh: _reset, child: zoomable)),
            ),
            if (!_selecting)
              // Between the top bar and the floating nav bar, so the handle
              // never slides underneath either.
              Positioned(
                top: MediaQuery.paddingOf(context).top,
                bottom: MediaQuery.paddingOf(context).bottom,
                right: 0,
                child: _Scrubber(controller: _scroll, labelAt: labelAt),
              ),
            if (_selecting) Positioned.fill(child: _selectionBars(context)),
          ]),
        ),
      );
    });
  }
}

/// Fast-scroll handle on the right edge. Appears while scrolling; drag it
/// to jump through time with a date bubble beside your finger.
class _Scrubber extends StatefulWidget {
  const _Scrubber({required this.controller, required this.labelAt});

  final ScrollController controller;
  final String Function(double offset) labelAt;

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  static const _thumb = 52.0;
  bool _visible = false;
  bool _dragging = false;
  Timer? _hide;
  String _lastLabel = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hide?.cancel();
    super.dispose();
  }

  void _onScroll() {
    _hide?.cancel();
    if (!_dragging) {
      _hide = Timer(1500.ms, () {
        if (mounted) setState(() => _visible = false);
      });
    }
    setState(() => _visible = true);
  }

  void _jump(double dy, double height) {
    final c = widget.controller;
    if (!c.hasClients) return;
    final f = ((dy - _thumb / 2) / (height - _thumb)).clamp(0.0, 1.0);
    c.jumpTo(f * c.position.maxScrollExtent);
    final label = widget.labelAt(c.offset);
    if (label != _lastLabel) {
      _lastLabel = label;
      Haptics.tick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final h = box.maxHeight;
      final max = c.hasClients ? c.position.maxScrollExtent : 0.0;
      // Only worth it when there's a lot to scroll through.
      if (max < h * 2) return const SizedBox.shrink();
      final top = (c.offset / max).clamp(0.0, 1.0) * (h - _thumb);
      return AnimatedOpacity(
        opacity: _visible || _dragging ? 1 : 0,
        duration: 200.ms,
        child: IgnorePointer(
          ignoring: !_visible && !_dragging,
          child: SizedBox(
            width: _dragging ? 220 : 36,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (d) {
                Haptics.lift();
                setState(() => _dragging = true);
                _jump(d.localPosition.dy, h);
              },
              onVerticalDragUpdate: (d) => _jump(d.localPosition.dy, h),
              onVerticalDragEnd: (_) {
                setState(() => _dragging = false);
                _onScroll();
              },
              child: Stack(children: [
                Positioned(
                  top: top,
                  right: 4,
                  height: _thumb,
                  child: Row(children: [
                    if (_dragging)
                      Container(
                        margin: const EdgeInsets.only(right: 10),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 8),
                          ],
                        ),
                        child: Text(widget.labelAt(c.offset),
                            style: TextStyle(
                                color: scheme.onPrimary,
                                fontWeight: FontWeight.w700)),
                      ).animate().scaleXY(
                          begin: 0.6,
                          alignment: Alignment.centerRight,
                          curve: Curves.easeOutBack),
                    AnimatedContainer(
                      duration: 150.ms,
                      width: _dragging ? 10 : 6,
                      decoration: BoxDecoration(
                        color: _dragging ? scheme.primary : scheme.outline,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

/// "Select this day" circle on a header.
class _DayCheck extends StatelessWidget {
  const _DayCheck({required this.all, required this.onTap});

  final bool all;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: AnimatedSwitcher(
        duration: 180.ms,
        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
        child: Icon(
          all ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
          key: ValueKey(all),
          color: all ? scheme.primary : scheme.outline,
        ),
      ),
    );
  }
}

String _duration(Duration d) {
  final m = d.inMinutes, sec = d.inSeconds % 60;
  return d.inHours > 0
      ? '${d.inHours}:${(m % 60).toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}'
      : '$m:${sec.toString().padLeft(2, '0')}';
}

/// Grid thumbnail with a play badge for videos and a heart for favourites.
/// While selecting it shows a check circle and shrinks a little when picked.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.asset,
    required this.px,
    required this.onTap,
    this.small = false,
    this.selecting = false,
    this.selected = false,
  });

  final AssetEntity asset;
  final VoidCallback onTap;

  /// Thumbnail size step for the tile's size on screen.
  final int px;

  /// Smaller thumbnails when many columns are shown.
  final bool small;
  final bool selecting, selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final video = asset.type == AssetType.video;
    const shadow = [Shadow(color: Colors.black54, blurRadius: 4)];
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        child: Stack(fit: StackFit.expand, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: selected ? 1 : 0),
            duration: 180.ms,
            curve: Curves.easeOutCubic,
            // Shrinks and rounds its corners together.
            builder: (context, t, child) => Transform.scale(
              scale: 1 - 0.16 * t,
              child: ClipRRect(borderRadius: BorderRadius.circular(12 * t), child: child),
            ),
            child: Hero(
                tag: 'photo-${asset.id}',
                child: Image(
                  image: FastThumb(asset.id, px, cover: true),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  frameBuilder: (context, child, frame, sync) => sync
                      ? child
                      : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: 160.ms, child: child),
                  errorBuilder: (context, _, _) =>
                      ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                ),
              ),
          ),
          if (video && !small)
            Positioned(
              right: 6,
              bottom: 5,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_duration(asset.videoDuration),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w700, shadows: shadow)),
                const SizedBox(width: 2),
                const Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white, shadows: shadow),
              ]),
            )
          else if (video)
            const Positioned(
                right: 3, bottom: 3, child: Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white, shadows: shadow)),
          if (asset.isFavorite && !small)
            const Positioned(
              left: 6,
              bottom: 5,
              child: Icon(Icons.favorite_rounded, size: 15, color: Colors.white, shadows: shadow),
            ),
          if (selecting)
            Positioned(
              top: 6,
              left: 6,
              child: AnimatedContainer(
                duration: 160.ms,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.black26,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 14, color: scheme.onPrimary)
                        .animate()
                        .scaleXY(begin: 0.3, duration: 200.ms, curve: Curves.easeOutBack)
                    : null,
              ),
            ),
        ]),
      ),
    );
  }
}
