import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anim.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'desktop_keys.dart';
import 'desktop_layout.dart';
import 'fast_thumb.dart';
import 'glass.dart';
import 'media_actions.dart';
import 'motion.dart';
import 'person_screen.dart';
import 'photo_info.dart';
import 'photo_side_panel.dart';
import 'theme.dart';
import 'widgets.dart';

/// Screen-sized photo step: sharp at 1x, without decoding the original.
int _viewStep(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final dpr = MediaQuery.devicePixelRatioOf(context);
  return FastThumb.step((size.longestSide * dpr * 0.6).clamp(1024, 2400));
}

/// Drag this far down (or flick) to close the viewer.
const _dismissDistance = 140.0;

/// The pull-up info panel takes this share of the screen.
const _panelShare = 0.58;

/// Full-screen photos: swipe sideways (with a slight 3D turn), pinch or
/// double-tap to zoom, tap a face to spotlight it, pull up for details and
/// swipe down to close. When [faces] has a box for a photo, that person's
/// face is outlined.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.ids,
    required this.initial,
    required this.controller,
    this.faces = const {},
    this.selection,
    this.onSelectionChanged,
    this.onRemoved,
    this.onChanged,
  });

  final List<String> ids;
  final int initial;
  final ScanController controller;

  /// When given, each photo can be selected or deselected here (the set is
  /// changed in place and [onSelectionChanged] is called).
  final Set<String>? selection;
  final VoidCallback? onSelectionChanged;

  /// Told about items deleted here, and items changed (favourite, album).
  final ValueChanged<Set<String>>? onRemoved;
  final ValueChanged<Set<String>>? onChanged;

  /// Normalized 0..1 face box per photo id.
  final Map<String, Rect> faces;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> with TickerProviderStateMixin {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late final List<String> _ids = List.of(widget.ids);
  bool _busy = false;

  /// Two or more fingers are down: they're zooming, so swipes (to the next
  /// photo, or down to close) stand aside.
  final Set<int> _fingers = {};
  bool get _multiTouch => _fingers.length > 1;

  void _finger(PointerEvent e, bool down) {
    final was = _multiTouch;
    down ? _fingers.add(e.pointer) : _fingers.remove(e.pointer);
    if (was != _multiTouch) setState(() {});
  }

  /// Gets the photos either side ready, so swiping never waits.
  void _preload(int i) {
    final px = _viewStep(context);
    for (final k in [i + 1, i - 1, i + 2]) {
      if (k < 0 || k >= _ids.length) continue;
      precacheImage(FastThumb(_ids[k], px), context, onError: (_, _) {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _preload(_index);
  }

  late int _index = widget.initial;
  bool _chrome = true;
  bool _highlight = true;
  bool _zoomed = false;

  /// Swipe-down-to-close drag.
  double _drag = 0;
  late final AnimationController _settle = AnimationController(vsync: this, duration: 250.ms)
    ..addListener(() => setState(() => _drag = _settleFrom * (1 - _settle.value)));
  double _settleFrom = 0;

  /// Info panel: 0 = hidden, 1 = fully open.
  double _info = 0;
  late final AnimationController _infoAnim = AnimationController(vsync: this, duration: 280.ms)
    ..addListener(
      () => setState(() => _info = lerpDouble(_infoFrom, _infoTo, Curves.easeOutCubic.transform(_infoAnim.value))!),
    );
  double _infoFrom = 0, _infoTo = 0;

  _SpotlightData? _spotlight;

  @override
  void initState() {
    super.initState();
    // Desktop: the filmstrip opens on the photo you clicked.
    if (DesktopLayout.on) WidgetsBinding.instance.addPostFrameCallback((_) => _centreFilmstrip(jump: true));
    DesktopKeys.escClaims.add(this);
  }

  @override
  void dispose() {
    DesktopKeys.escClaims.remove(this);
    _zoomCmd.dispose();
    _pages.dispose();
    _settle.dispose();
    _infoAnim.dispose();
    _keys.dispose();
    _film.dispose();
    super.dispose();
  }

  double get _panelHeight => MediaQuery.sizeOf(context).height * _panelShare;

  void _toggleSelected() {
    final sel = widget.selection;
    if (sel == null) return;
    final id = _ids[_index];
    Haptics.tick();
    setState(() => sel.contains(id) ? sel.remove(id) : sel.add(id));
    widget.onSelectionChanged?.call();
  }

  Future<void> _act(Future<void> Function(MediaActions a, AssetEntity asset) f) async {
    if (_busy) return;
    final asset = await AssetThumb.entity(_ids[_index]);
    if (asset == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await f(MediaActions(context, widget.controller), asset);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trash(MediaActions a, AssetEntity asset) async {
    if (!await a.confirmTrash(1)) return;
    final gone = await a.trash([asset]);
    if (gone.isEmpty || !mounted) return;
    widget.onRemoved?.call(gone);
    if (_ids.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _ids.removeAt(_index);
      if (_index >= _ids.length) _index = _ids.length - 1;
    });
    _pages.jumpToPage(_index);
  }

  Widget _actionBar() => FutureBuilder<AssetEntity?>(
    future: AssetThumb.entity(_ids[_index]),
    initialData: AssetThumb.peek(_ids[_index]),
    builder: (context, snap) => MediaActionBar(
      kind: GlassKind.clear,
      favourite: snap.data?.isFavorite ?? false,
      onSend: _busy ? null : () => _act((a, x) => a.send([x])),
      onShare: _busy ? null : () => _act((a, x) => a.share([x])),
      onFavourite: _busy
          ? null
          : () => _act((a, x) async {
              if (await a.toggleFavourite([x]) != null) widget.onChanged?.call({x.id});
            }),
      onAlbum: _busy
          ? null
          : () => _act((a, x) async {
              await a.addToAlbum([x]);
              widget.onChanged?.call({x.id});
            }),
      onTrash: _busy ? null : () => _act(_trash),
    ),
  );

  void _animateInfo(double to) {
    _infoFrom = _info;
    _infoTo = to;
    _infoAnim.forward(from: 0);
  }

  void _dragUpdate(DragUpdateDetails d) {
    setState(() {
      if (_info > 0 || (d.delta.dy < 0 && _drag <= 0)) {
        _info = (_info - d.delta.dy / _panelHeight).clamp(0.0, 1.0);
      } else {
        _drag += d.delta.dy;
      }
    });
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (_info > 0) {
      _animateInfo(v < -300 || (_info > 0.4 && v < 300) ? 1 : 0);
      return;
    }
    if (_drag > _dismissDistance || v > 900) {
      Navigator.pop(context);
      return;
    }
    _settleFrom = _drag;
    _settle.forward(from: 0);
  }

  void _toggleChrome() {
    if (_info > 0) {
      _animateInfo(0);
    } else {
      setState(() => _chrome = !_chrome);
    }
  }

  /// The photos themselves, one page each: swiped on a phone, stepped with
  /// the keys, arrows and filmstrip on desktop.
  Widget _photoPages() {
    final desktop = DesktopLayout.on;
    return PageView.builder(
      controller: _pages,
      // Keeps the next and previous pages built, so they're ready.
      allowImplicitScrolling: true,
      physics: _zoomed || _info > 0 || _multiTouch
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(parent: BouncingScrollPhysics()),
      itemCount: _ids.length,
      onPageChanged: (i) {
        Haptics.tick();
        setState(() {
          _index = i;
          _zoomed = false;
        });
        _preload(i);
        _centreFilmstrip();
      },
      itemBuilder: (context, i) => AnimatedBuilder(
        animation: _pages,
        builder: (context, child) {
          // Layered cards: the photo on the left drifts a
          // little slower and sinks back while the one on the
          // right slides over it at full speed, so the two
          // never cross-blend. The tree keeps the same shape
          // at rest; changing it would rebuild the page (and
          // reload its photo) every time a swipe starts.
          final page = _pages.hasClients && _pages.position.haveDimensions
              ? _pages.page ?? _index.toDouble()
              : _index.toDouble();
          final back = (page - i).clamp(0.0, 1.0);
          final t = Curves.easeOut.transform(back);
          final width = MediaQuery.sizeOf(context).width;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(back * width * 0.3, 0, 0)
              ..scaleByDouble(1 - t * 0.08, 1 - t * 0.08, 1, 1),
            child: Opacity(opacity: 1 - t * 0.45, child: child),
          );
        },
        child: RepaintBoundary(
          child: _ZoomPage(
            key: ValueKey(_ids[i]),
            id: _ids[i],
            active: i == _index,
            face: widget.faces[_ids[i]],
            highlight: _highlight && i == _index,
            // Desktop outlines every face, with names.
            outlines: desktop && _highlight,
            db: widget.controller.db,
            commands: _zoomCmd,
            onZoomChanged: (z) {
              if (i == _index && z != _zoomed) setState(() => _zoomed = z);
            },
            onFaceTap: (data) {
              Haptics.lift();
              setState(() => _spotlight = data);
            },
            // A click beside the faces does nothing on desktop: the bars
            // stay put for the mouse.
            onMiss: desktop ? () {} : _toggleChrome,
          ),
        ),
      ),
    );
  }

  // ---- Desktop ----

  // Two-finger swipe on a touchpad: how far it went sideways, on which
  // photo it started, and whether it turned into a pinch.
  double _swipeDx = 0;
  int _swipeFrom = 0;
  bool _swipePinch = false;

  void _swipeStart(PointerPanZoomStartEvent e) {
    _swipeDx = 0;
    _swipeFrom = _index;
    _swipePinch = false;
  }

  void _swipeUpdate(PointerPanZoomUpdateEvent e) {
    if ((e.scale - 1).abs() > 0.04) _swipePinch = true;
    _swipeDx = e.pan.dx;
  }

  void _swipeEnd(PointerPanZoomEndEvent e) {
    // Zoomed in, the fingers move the photo; a pinch zooms. And if the
    // pages already turned with the fingers, that was the swipe.
    if (_zoomed || _swipePinch || _index != _swipeFrom) return;
    if (_swipeDx.abs() < 90) return;
    _go(_index + (_swipeDx < 0 ? 1 : -1));
  }

  /// Keys go to the viewer as soon as it opens.
  final _keys = FocusNode(debugLabel: 'Photo viewer');

  /// The info panel beside the photo (wide windows); toggled with I.
  bool _panel = true;

  final _film = ScrollController();

  /// One thumbnail in the filmstrip plus the gap after it.
  static const _filmItem = 54.0;

  /// Steps to photo [i]: a slide to the next one, a jump further away.
  void _go(int i) {
    if (i < 0 || i >= _ids.length || i == _index || !_pages.hasClients) return;
    if ((i - _index).abs() == 1) {
      _pages.animateToPage(i, duration: 280.ms, curve: Curves.easeOutCubic);
    } else {
      _pages.jumpToPage(i);
    }
  }

  /// Keeps the current photo in the middle of the filmstrip.
  void _centreFilmstrip({bool jump = false}) {
    if (!_film.hasClients) return;
    final view = _film.position.viewportDimension;
    final target = (_index * _filmItem - (view - _filmItem) / 2).clamp(0.0, _film.position.maxScrollExtent);
    jump ? _film.jumpTo(target) : _film.animateTo(target, duration: 250.ms, curve: Curves.easeOutCubic);
  }

  void _toggleInfo() {
    if (DesktopLayout.wide(context)) {
      setState(() => _panel = !_panel);
    } else {
      showPhotoInfo(context, _ids[_index], widget.controller);
    }
  }

  /// Zoom asked for from the keyboard; the photo on screen follows it.
  final _zoomCmd = _ZoomCommand();

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    // Alt + Left is "back" (closes the viewer), not the previous photo.
    if (HardwareKeyboard.instance.isAltPressed || HardwareKeyboard.instance.isControlPressed) {
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.numpadAdd) {
      _zoomCmd.send(1.25);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      _zoomCmd.send(0.8);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
      _zoomCmd.send(0);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.home && !repeat) {
      _go(0);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.end && !repeat) {
      _go(_ids.length - 1);
      return KeyEventResult.handled;
    } else if (k == LogicalKeyboardKey.delete && !repeat) {
      if (!_busy) _act(_trash);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _go(_index - 1);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      _go(_index + 1);
    } else if (repeat) {
      return KeyEventResult.ignored;
    } else if (k == LogicalKeyboardKey.escape) {
      if (_spotlight != null) {
        setState(() => _spotlight = null);
      } else {
        Navigator.maybePop(context);
      }
    } else if (k == LogicalKeyboardKey.keyF) {
      setState(() => _highlight = !_highlight);
    } else if (k == LogicalKeyboardKey.keyI) {
      _toggleInfo();
    } else if (k == LogicalKeyboardKey.space && widget.selection != null) {
      _toggleSelected();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Desktop: a top bar, the photo with arrows either side, a filmstrip
  /// below and (on wide windows) the info panel on the right.
  Widget _desktopBuild(BuildContext context) {
    final id = _ids[_index];
    final panel = _panel && DesktopLayout.wide(context);
    return Scaffold(
      backgroundColor: const Color(0xFF08070A),
      body: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(children: [
          Row(children: [
            Expanded(
              child: Column(children: [
                _desktopTopBar(id, panel),
                Expanded(
                  child: Stack(children: [
                    Positioned.fill(
                      child: Listener(
                        onPointerPanZoomStart: _swipeStart,
                        onPointerPanZoomUpdate: _swipeUpdate,
                        onPointerPanZoomEnd: _swipeEnd,
                        child: _photoPages(),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _RoundArrow(
                          icon: Icons.chevron_left_rounded,
                          tooltip: 'Previous (←)',
                          onTap: _index > 0 ? () => _go(_index - 1) : null,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 14,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _RoundArrow(
                          icon: Icons.chevron_right_rounded,
                          tooltip: 'Next (→)',
                          onTap: _index < _ids.length - 1 ? () => _go(_index + 1) : null,
                        ),
                      ),
                    ),
                    // Select toggle for a picking viewer.
                    if (widget.selection != null && _spotlight == null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 16,
                        child: Center(
                          child: _SelectPill(selected: widget.selection!.contains(id), onTap: _toggleSelected),
                        ),
                      ),
                    // The actions live in the panel when it's open.
                    if (widget.selection == null && !panel)
                      Positioned(
                        left: 80,
                        right: 80,
                        bottom: 14,
                        child: Center(
                          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: _actionBar()),
                        ),
                      ),
                  ]),
                ),
                _filmstrip(),
              ]),
            ),
            if (panel)
              PhotoSidePanel(
                assetId: id,
                controller: widget.controller,
                onSend: _busy ? null : () => _act((a, x) => a.send([x])),
                onShowInFolder: _busy ? null : () => _act((a, x) => a.share([x])),
                onDelete: _busy ? null : () => _act(_trash),
              ),
          ]),
          if (_spotlight != null)
            Positioned.fill(
              child: _Spotlight(
                key: ValueKey(_spotlight),
                data: _spotlight!,
                controller: widget.controller,
                onClosed: () => setState(() => _spotlight = null),
              ),
            ),
        ]),
      ),
    );
  }

  /// Back, the file name and date, and the outline and info toggles.
  Widget _desktopTopBar(String id, bool panel) {
    const dim = Color(0xB3F2EFF5);
    const faint = Color(0x73F2EFF5);
    final count = widget.selection == null
        ? '${_index + 1} of ${_ids.length}'
        : '${_index + 1} of ${_ids.length} · ${_ids.where(widget.selection!.contains).length} selected';
    Widget toggle({required IconData icon, required String tooltip, required bool on, required VoidCallback onTap}) =>
        IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          icon: Icon(icon, size: 21, color: on ? Brand.accentDark : dim),
        );
    // The buttons never take the keyboard: the arrow keys stay with the
    // photos.
    return ExcludeFocus(
      child: SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          IconButton(
            tooltip: 'Back (Esc)',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back_rounded, size: 21, color: dim),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FutureBuilder<AssetEntity?>(
              future: AssetThumb.entity(id),
              initialData: AssetThumb.peek(id),
              builder: (context, snap) {
                final a = snap.data;
                final when = a == null ? '' : '${formatSectionDay(a.createDateTime)} · ${formatTime(a.createDateTime)} · ';
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: TextSize.label, fontWeight: FontWeight.w600)),
                    Text('$when$count',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: faint, fontSize: TextSize.small)),
                  ],
                );
              },
            ),
          ),
          toggle(
            icon: _highlight ? Icons.center_focus_strong : Icons.center_focus_weak,
            tooltip: _highlight ? 'Hide face outlines (F)' : 'Show face outlines (F)',
            on: _highlight,
            onTap: () => setState(() => _highlight = !_highlight),
          ),
          toggle(
            icon: panel ? Icons.info_rounded : Icons.info_outline_rounded,
            tooltip: panel ? 'Hide info (I)' : 'Info (I)',
            on: panel,
            onTap: _toggleInfo,
          ),
        ]),
      ),
      ),
    );
  }

  /// Small squares of the photos; the current one is outlined.
  Widget _filmstrip() {
    return SizedBox(
      height: 76,
      child: LayoutBuilder(builder: (context, box) {
        // Short lists sit in the middle; long ones scroll.
        final side = math.max(8.0, (box.maxWidth - _ids.length * _filmItem) / 2);
        return ListView.builder(
          controller: _film,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: side, vertical: 13),
          itemExtent: _filmItem,
          itemCount: _ids.length,
          itemBuilder: (context, i) => _FilmThumb(
            id: _ids[i],
            current: i == _index,
            onTap: () => _go(i),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopLayout.on) return _desktopBuild(context);
    final size = MediaQuery.sizeOf(context);
    final hasFaces = widget.faces.isNotEmpty;
    // 0 = resting, 1 = dragged far enough to close.
    final progress = (_drag.clamp(0, 300) / 300).toDouble();
    final id = _ids[_index];
    final panelH = size.height * _panelShare;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: IgnorePointer(
          ignoring: !(_chrome && _drag == 0 && _info == 0 && _spotlight == null),
          child: AnimatedOpacity(
            opacity: _chrome && _drag == 0 && _info == 0 && _spotlight == null ? 1 : 0,
            duration: 200.ms,
            // Clear glass floats over the photo instead of a dark bar.
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    GlassIconButton(
                      kind: GlassKind.clear,
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 8),
                    // Takes all the room between the buttons and sits at its
                    // left, so the buttons on the right stay at the edge. (A
                    // Flexible next to a Spacer split the room and left them
                    // stranded mid-bar.)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Glass(
                          kind: GlassKind.clear,
                          shadow: false,
                          radius: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Text(
                            widget.selection == null
                                ? '${_index + 1} / ${_ids.length}'
                                : '${_index + 1} / ${_ids.length} · '
                                      '${_ids.where(widget.selection!.contains).length} selected',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (hasFaces) ...[
                      GlassIconButton(
                        kind: GlassKind.clear,
                        tooltip: _highlight ? 'Hide face outline' : 'Show face outline',
                        icon: Icon(_highlight ? Icons.center_focus_strong : Icons.center_focus_weak),
                        onPressed: () => setState(() => _highlight = !_highlight),
                      ),
                      const SizedBox(width: 8),
                    ],
                    GlassIconButton(
                      kind: GlassKind.clear,
                      tooltip: 'Info',
                      icon: const Icon(Icons.info_outline_rounded),
                      onPressed: () => _animateInfo(1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: 1 - progress,
              child: RepaintBoundary(child: _BlurredBackdrop(id: id)),
            ),
          ),
          Listener(
            onPointerDown: (e) => _finger(e, true),
            onPointerUp: (e) => _finger(e, false),
            onPointerCancel: (e) => _finger(e, false),
            child: GestureDetector(
              onTap: _toggleChrome,
              onVerticalDragUpdate: _zoomed || _multiTouch ? null : _dragUpdate,
              onVerticalDragEnd: _zoomed || _multiTouch ? null : _dragEnd,
              // As the info panel rises, the photo shrinks up above it.
              child: Transform.translate(
                offset: Offset(0, _drag - _info * panelH * 0.5),
                child: Transform.scale(
                  scale: (1 - progress * 0.35) * (1 - _info * 0.38),
                  child: _photoPages(),
                ),
              ),
            ),
          ),
          // Pull-up details panel.
          Positioned(
            left: 0,
            right: 0,
            height: panelH,
            bottom: -panelH * (1 - _info),
            child: IgnorePointer(
              ignoring: _info == 0,
              child: Material(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _dragUpdate,
                      onVerticalDragEnd: _dragEnd,
                      child: const SizedBox(
                        height: 28,
                        width: double.infinity,
                        child: Center(
                          child: SizedBox(
                            width: 36,
                            height: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.grey,
                                borderRadius: BorderRadius.all(Radius.circular(2)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _info == 0
                          ? const SizedBox.shrink()
                          : SingleChildScrollView(
                              child: PhotoInfoPanel(
                                key: ValueKey(id),
                                assetId: id,
                                controller: widget.controller,
                                embedded: true,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Big select button within thumb reach.
          if (widget.selection != null && _info == 0 && _spotlight == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24 + MediaQuery.paddingOf(context).bottom,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _drag == 0 ? 1 : 0,
                  duration: 150.ms,
                  child: _SelectPill(selected: widget.selection!.contains(id), onTap: _toggleSelected),
                ),
              ),
            ),
          // Gallery actions within thumb reach.
          if (widget.selection == null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              child: IgnorePointer(
                ignoring: !(_chrome && _drag == 0 && _info == 0 && _spotlight == null),
                child: AnimatedSlide(
                  offset: _chrome && _drag == 0 && _info == 0 && _spotlight == null
                      ? Offset.zero
                      : const Offset(0, 0.6),
                  duration: 220.ms,
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: _chrome && _drag == 0 && _info == 0 && _spotlight == null ? 1 : 0,
                    duration: 200.ms,
                    child: _actionBar(),
                  ),
                ),
              ),
            ),
          if (_spotlight != null)
            Positioned.fill(
              child: _Spotlight(
                key: ValueKey(_spotlight),
                data: _spotlight!,
                controller: widget.controller,
                onClosed: () => setState(() => _spotlight = null),
              ),
            ),
        ],
      ),
    );
  }
}

/// A soft, dark, heavily blurred copy of the photo behind it.
class _BlurredBackdrop extends StatelessWidget {
  const _BlurredBackdrop({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: 500.ms,
      child: FutureBuilder<AssetEntity?>(
        key: ValueKey(id),
        future: AssetThumb.entity(id),
        builder: (context, snap) {
          final asset = snap.data;
          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              // A tiny thumbnail stretched to fill the screen reads as a soft
              // blur, without running a full-screen blur filter every frame
              // while you swipe.
              if (asset != null)
                LibraryImage(asset, size: 32, filterQuality: FilterQuality.medium),
              const ColoredBox(color: Colors.black45),
            ],
          );
        },
      ),
    );
  }
}

/// Everything the spotlight needs to grow a face out of the photo.
class _SpotlightData {
  _SpotlightData({required this.asset, required this.photoRect, required this.face, required this.person});

  final AssetEntity asset;

  /// Where the photo sits on screen.
  final Rect photoRect;

  /// Normalized 0..1 face box within the photo.
  final Rect face;
  final PhotoPerson? person;
}

/// One photo with pinch zoom, animated double-tap zoom and tappable faces.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({
    super.key,
    required this.id,
    required this.active,
    required this.face,
    required this.highlight,
    this.outlines = false,
    required this.db,
    this.commands,
    required this.onZoomChanged,
    required this.onFaceTap,
    required this.onMiss,
  });

  final String id;

  /// Zoom in, out or back to fit, from the keyboard (desktop).
  final _ZoomCommand? commands;

  /// The page being looked at (videos stop when you swipe away).
  final bool active;
  final Rect? face;
  final bool highlight;

  /// Desktop: every face outlined, with its name (or "Add a name") below.
  final bool outlines;
  final AppDb db;
  final ValueChanged<bool> onZoomChanged;
  final ValueChanged<_SpotlightData> onFaceTap;

  /// A tap on the photo that didn't hit a face.
  final VoidCallback onMiss;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnim = AnimationController(vsync: this, duration: 280.ms);
  Animation<Matrix4>? _zoomTween;
  Offset _tapAt = Offset.zero;
  final _photoKey = GlobalKey();
  late final Future<List<({Rect box, PhotoPerson? person})>> _faces = widget.db.facesInPhoto(widget.id);

  @override
  void initState() {
    super.initState();
    _zoomAnim.addListener(() {
      if (_zoomTween != null) _transform.value = _zoomTween!.value;
    });
    _transform.addListener(_report);
    widget.commands?.addListener(_command);
  }

  @override
  void didUpdateWidget(_ZoomPage old) {
    super.didUpdateWidget(old);
    if (old.commands != widget.commands) {
      old.commands?.removeListener(_command);
      widget.commands?.addListener(_command);
    }
  }

  /// + / − / 0 on the keyboard: zoom around the middle of the view, or fit.
  void _command() {
    final f = widget.commands?.factor;
    final size = context.size;
    if (!widget.active || f == null || size == null) return;
    final now = _transform.value.getMaxScaleOnAxis();
    final scale = f == 0 ? 1.0 : (now * f).clamp(1.0, 6.0);
    Matrix4 target;
    if (scale <= 1.001) {
      target = Matrix4.identity();
    } else {
      final centre = size.center(Offset.zero);
      final scene = _transform.toScene(centre);
      target = Matrix4.identity()
        ..translateByDouble(centre.dx - scene.dx * scale, centre.dy - scene.dy * scale, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomTween = Matrix4Tween(begin: _transform.value, end: target)
        .animate(CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic));
    _zoomAnim.forward(from: 0);
  }

  @override
  void dispose() {
    widget.commands?.removeListener(_command);
    _transform.dispose();
    _zoomAnim.dispose();
    super.dispose();
  }

  bool get _isZoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  /// Zoomed in far enough to need more pixels than the screen-sized copy.
  bool _deepZoom = false;

  /// One-finger panning only means something once zoomed in; at rest a
  /// sideways swipe belongs to the pages.
  bool _panning = false;

  void _report() {
    final zoomed = _isZoomed;
    widget.onZoomChanged(zoomed);
    final deep = _transform.value.getMaxScaleOnAxis() > 1.8;
    if ((deep && !_deepZoom) || zoomed != _panning) {
      setState(() {
        _deepZoom = _deepZoom || deep;
        _panning = zoomed;
      });
    }
  }

  void _doubleTap() {
    const scale = 2.5;
    final target = _isZoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-_tapAt.dx * (scale - 1), -_tapAt.dy * (scale - 1), 0, 1)
            ..scaleByDouble(scale, scale, 1, 1));
    _zoomTween = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOutCubic));
    _zoomAnim.forward(from: 0);
  }

  /// Tapping inside a face box spotlights that face. Returns false if the
  /// tap missed every face (so the viewer can toggle its controls instead).
  Future<bool> _tapFace(Offset local, Size photo, AssetEntity asset) async {
    if (_isZoomed) return false;
    final p = Offset(local.dx / photo.width, local.dy / photo.height);
    for (final f in await _faces) {
      if (f.box.inflate(0.03).contains(p)) {
        final box = _photoKey.currentContext?.findRenderObject() as RenderBox?;
        if (box == null) return false;
        widget.onFaceTap(
          _SpotlightData(
            asset: asset,
            photoRect: box.localToGlobal(Offset.zero) & box.size,
            face: f.box,
            person: f.person,
          ),
        );
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Only the photo on screen flies back to its grid tile. The pages on
    // either side stay built (ready for a swipe) but must not fly too.
    return HeroMode(enabled: widget.active, child: _page(context));
  }

  Widget _page(BuildContext context) {
    return FutureBuilder<AssetEntity?>(
      future: AssetThumb.entity(widget.id),
      // Usually known already (from the grid): no empty first frame.
      initialData: AssetThumb.peek(widget.id),
      builder: (context, snap) {
        final asset = snap.data;
        if (asset != null && asset.type == AssetType.video) {
          return Hero(
            tag: 'photo-${widget.id}',
            child: _VideoPage(asset: asset, active: widget.active, onTap: widget.onMiss),
          );
        }
        return Hero(
          tag: 'photo-${widget.id}',
          child: asset == null
              ? const SizedBox.expand()
              : GestureDetector(
                  onDoubleTapDown: (d) => _tapAt = d.localPosition,
                  onDoubleTap: _doubleTap,
                  child: InteractiveViewer(
                    transformationController: _transform,
                    panEnabled: _panning,
                    maxScale: 6,
                    // Lets go of the edges smoothly instead of stopping dead.
                    interactionEndFrictionCoefficient: 0.0001,
                    child: LayoutBuilder(builder: (context, box) => _photo(asset, box)),
                  ),
                ),
        );
      },
    );
  }

  Widget _photo(AssetEntity asset, BoxConstraints box) {
    // As shown (turned upright), not as stored.
    final ow = asset.orientatedWidth, oh = asset.orientatedHeight;
    final aspect = ow > 0 && oh > 0 ? ow / oh : 1.0;
    // Size of the photo once fitted inside the screen.
    var w = box.maxWidth, h = w / aspect;
    if (h > box.maxHeight) {
      h = box.maxHeight;
      w = h * aspect;
    }
    final f = widget.face;
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTapUp: (d) async {
          if (!await _tapFace(d.localPosition, Size(w, h), asset)) {
            widget.onMiss();
          }
        },
        child: SizedBox(
          key: _photoKey,
          width: w,
          height: h,
          child: Stack(
            children: [
              // The grid's thumbnail (already in memory) shows at once; the
              // sharp version fades in over it, and a finer one when zoomed.
              Positioned.fill(
                child: Image(
                  image: FastThumb(widget.id, FastThumb.gridStep, cover: true),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              Positioned.fill(
                child: Image(
                  image: FastThumb(widget.id, _viewStep(context)),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
                  frameBuilder: (context, child, frame, sync) =>
                      sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: 180.ms, child: child),
                ),
              ),
              if (_deepZoom)
                Positioned.fill(
                  child: Image(
                    image: FastThumb(widget.id, 4096, quality: 90),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    frameBuilder: (context, child, frame, sync) =>
                        AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: 200.ms, child: child),
                  ),
                ),
              if (widget.outlines)
                Positioned.fill(
                  child: IgnorePointer(
                    child: FutureBuilder<List<({Rect box, PhotoPerson? person})>>(
                      future: _faces,
                      builder: (context, snap) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          for (final (i, face) in (snap.data ?? const <({Rect box, PhotoPerson? person})>[]).indexed)
                            Positioned(
                              left: face.box.left * w,
                              top: face.box.top * h,
                              width: face.box.width * w,
                              height: face.box.height * h,
                              child: _FaceOutline(person: face.person)
                                  .animate()
                                  .fadeIn(delay: (60 * i).ms, duration: 220.ms)
                                  .scaleXY(begin: 1.15, delay: (60 * i).ms, duration: 320.ms, curve: Curves.easeOutBack),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              // The person's own face, when opened from their page (desktop
              // outlines every face instead).
              if (f != null && !widget.outlines)
                Positioned(
                  left: f.left * w - 6,
                  top: f.top * h - 6,
                  width: f.width * w + 12,
                  height: f.height * h + 12,
                  child: AnimatedOpacity(
                    opacity: widget.highlight ? 1 : 0,
                    duration: 250.ms,
                    child:
                        DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white, width: 2.5),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
                              ),
                            )
                            .animate(target: widget.highlight ? 1 : 0)
                            .scale(
                              begin: const Offset(1.4, 1.4),
                              end: const Offset(1, 1),
                              duration: 400.ms,
                              curve: Curves.easeOutBack,
                            ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tapped face grows out of the photo into a big rounded card while
/// everything else dims and blurs; the person's name floats up below it.
class _Spotlight extends StatefulWidget {
  const _Spotlight({super.key, required this.data, required this.controller, required this.onClosed});

  final _SpotlightData data;
  final ScanController controller;
  final VoidCallback onClosed;

  @override
  State<_Spotlight> createState() => _SpotlightState();
}

class _SpotlightState extends State<_Spotlight> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: 480.ms)..forward();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _anim.reverse();
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final d = widget.data;
    final photo = d.photoRect;
    // A little room around the face, kept inside the photo.
    final face = Rect.fromLTRB(
      math.max(0, d.face.left - d.face.width * 0.25),
      math.max(0, d.face.top - d.face.height * 0.25),
      math.min(1, d.face.right + d.face.width * 0.25),
      math.min(1, d.face.bottom + d.face.height * 0.25),
    );
    final from = Rect.fromLTWH(
      photo.left + face.left * photo.width,
      photo.top + face.top * photo.height,
      face.width * photo.width,
      face.height * photo.height,
    );
    final side = math.min(screen.width * 0.78, 340.0);
    final aspect = from.width / from.height;
    final toW = aspect >= 1 ? side : side * aspect;
    final toH = aspect >= 1 ? side / aspect : side;
    final to = Rect.fromCenter(center: Offset(screen.width / 2, screen.height * 0.42), width: toW, height: toH);

    return GestureDetector(
      onTap: _close,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final t = Curves.easeOutCubic.transform(_anim.value);
          final cur = Rect.lerp(from, to, t)!;
          final k = cur.width / from.width;
          final person = d.person;
          return Stack(
            children: [
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
                  child: ColoredBox(color: Colors.black.withAlpha((150 * t).round())),
                ),
              ),
              Positioned.fromRect(
                rect: cur,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28 * t),
                    boxShadow: [BoxShadow(color: Colors.black.withAlpha((120 * t).round()), blurRadius: 30)],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28 * t),
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform.translate(
                        offset: Offset(-(from.left - photo.left) * k, -(from.top - photo.top) * k),
                        child: SizedBox(
                          width: photo.width * k,
                          height: photo.height * k,
                          child: LibraryImage(d.asset, size: 2000, fit: BoxFit.fill),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: cur.bottom + 20,
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, 20 * (1 - t)),
                    child: Center(
                      child: person == null
                          ? const Chip(label: Text('Not recognised yet'))
                          : ActionChip(
                              avatar: CircleAvatar(backgroundImage: MemoryImage(person.thumb)),
                              label: Text(person.displayName),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => PersonScreen(controller: widget.controller, personId: person.id),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Desktop: a rounded box on a face with the person's name in a pill below
/// it; faces without a name get a dashed coral box and "Add a name".
class _FaceOutline extends StatelessWidget {
  const _FaceOutline({required this.person});

  final PhotoPerson? person;

  @override
  Widget build(BuildContext context) {
    const accent = Brand.accentDark;
    final name = person?.name;
    final box = name == null
        ? const CustomPaint(painter: _DashedRRect(color: accent), child: SizedBox.expand())
        : DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withAlpha(230), width: 2),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [BoxShadow(color: Color(0x40000000), spreadRadius: 1)],
            ),
            child: const SizedBox.expand(),
          );
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: box),
      Positioned(
        left: -80,
        right: -80,
        bottom: -30,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xD1141219),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              name ?? 'Add a name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: name == null ? accent : Colors.white,
                fontSize: TextSize.tiny,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// The dashed box of a face that has no name yet.
class _DashedRRect extends CustomPainter {
  const _DashedRRect({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 6, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRect old) => old.color != color;
}

/// Desktop: the round previous / next buttons beside the photo. Hidden at
/// either end.
class _RoundArrow extends StatefulWidget {
  const _RoundArrow({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_RoundArrow> createState() => _RoundArrowState();
}

class _RoundArrowState extends State<_RoundArrow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    return IgnorePointer(
      ignoring: !on,
      child: AnimatedOpacity(
        opacity: on ? (_hover ? 1 : 0.75) : 0,
        duration: 150.ms,
        child: Tooltip(
          message: widget.tooltip,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: 150.ms,
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withAlpha(_hover ? 38 : 20),
                ),
                child: Icon(widget.icon, color: Colors.white, size: 26),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One square in the desktop filmstrip.
class _FilmThumb extends StatefulWidget {
  const _FilmThumb({required this.id, required this.current, required this.onTap});

  final String id;
  final bool current;
  final VoidCallback onTap;

  @override
  State<_FilmThumb> createState() => _FilmThumbState();
}

class _FilmThumbState extends State<_FilmThumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: 150.ms,
            transform: Matrix4.translationValues(0, _hover && !widget.current ? -2 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: widget.current ? Brand.accentDark : Colors.transparent, width: 2),
            ),
            padding: const EdgeInsets.all(2),
            child: AnimatedOpacity(
              duration: 150.ms,
              opacity: widget.current ? 1 : (_hover ? 0.9 : 0.45),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Image(
                  image: FastThumb(widget.id, FastThumb.step(128), cover: true),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, _, _) => const ColoredBox(color: Color(0xFF1C1A22)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Selected ✓" / "Select" toggle at the bottom of the viewer.
class _SelectPill extends StatelessWidget {
  const _SelectPill({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : Colors.white;
    return Pressable(
      onTap: onTap,
      child: Glass(
        kind: GlassKind.clear,
        tint: selected ? scheme.primary : null,
        radius: 30,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: fg),
            const SizedBox(width: 8),
            Text(
              selected ? 'Selected' : 'Select',
              style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: TextSize.body),
            ),
          ],
        ),
      ),
    ).animate(key: ValueKey(selected)).scaleXY(begin: 0.88, duration: 380.ms, curve: Curves.elasticOut);
  }
}

/// A video: its poster with a play button, then the player with a
/// scrubber. Pauses when you swipe to another page.
class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.asset, required this.active, required this.onTap});

  final AssetEntity asset;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _video;
  bool _starting = false;
  String? _error;

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    if (!widget.active) _video?.pause();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final v = _video;
    if (v != null) {
      v.value.isPlaying ? await v.pause() : await v.play();
      return;
    }
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final file = await widget.asset.file;
      if (file == null) throw StateError('The video file is missing');
      final c = VideoPlayerController.file(file);
      await c.initialize();
      c.addListener(() {
        if (mounted) setState(() {});
      });
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _video = c);
      await c.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'Can\'t play this video');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    final v = _video;
    final aspect = v != null && v.value.isInitialized
        ? v.value.aspectRatio
        : (a.orientatedWidth > 0 && a.orientatedHeight > 0 ? a.orientatedWidth / a.orientatedHeight : 16 / 9);
    final playing = v?.value.isPlaying ?? false;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: aspect,
              child: v != null && v.value.isInitialized
                  ? VideoPlayer(v)
                  : LibraryImage(a, size: 1200, fit: BoxFit.contain),
            ),
          ),
          // The big play button fades away while playing.
          AnimatedOpacity(
            opacity: playing ? 0 : 1,
            duration: 200.ms,
            child: GestureDetector(
              onTap: _play,
              child: Glass(
                kind: GlassKind.clear,
                radius: 40,
                child: SizedBox.square(
                  dimension: 76,
                  child: _starting
                      ? const Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 46, color: Colors.white),
                ),
              ),
            ),
          ),
          if (_error != null)
            Positioned(
              bottom: 140,
              child: Text(_error!, style: const TextStyle(color: Colors.white)),
            ),
          if (v != null && v.value.isInitialized)
            Positioned(
              left: 16,
              right: 16,
              bottom: 110 + MediaQuery.paddingOf(context).bottom,
              child: Glass(
                kind: GlassKind.clear,
                radius: 22,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _play,
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    ),
                    Text(_time(v.value.position), style: const TextStyle(color: Colors.white, fontSize: TextSize.small)),
                    Expanded(
                      child: Slider(
                        value: v.value.position.inMilliseconds.clamp(0, v.value.duration.inMilliseconds).toDouble(),
                        max: v.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                        onChanged: (x) => v.seekTo(Duration(milliseconds: x.round())),
                      ),
                    ),
                    Text(_time(v.value.duration), style: const TextStyle(color: Colors.white, fontSize: TextSize.small)),
                    IconButton(
                      onPressed: () => v.setVolume(v.value.volume > 0 ? 0 : 1),
                      icon: Icon(
                        v.value.volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(duration: 200.ms).moveY(begin: 12),
        ],
      ),
    );
  }
}

/// Zoom steps sent from the keyboard to the photo on screen: a factor to
/// multiply the zoom by, or 0 to fit the photo again.
class _ZoomCommand extends ChangeNotifier {
  double factor = 1;

  void send(double f) {
    factor = f;
    notifyListeners();
  }
}
