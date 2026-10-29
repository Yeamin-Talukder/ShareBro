import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'face_cloud.dart';
import 'glass.dart';
import 'group_editor.dart';
import 'motion.dart';
import 'person_screen.dart';
import 'review_screen.dart';
import 'scan_screen.dart';
import 'scan_sheet.dart';
import 'send_center_screen.dart';
import 'settings_screen.dart';
import 'timeline_screen.dart';
import 'together_screen.dart';
import 'widgets.dart';

/// Room under the last row for the Scan button floating above the nav bar.
const _fabClearance = 88.0;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ScanController get c => widget.controller;
  List<PersonSummary>? _people;
  List<TripSummary> _trips = const [];
  int _reviewCount = 0;
  int? _tripId;
  DaySpan? _dates;
  List<PersonGroup> _groups = const [];
  int? _groupId;
  int _loadedRevision = -1;

  /// Floating bubble view instead of the grid.
  bool _cloud = false;

  /// Person that just absorbed a drag-merge; plays a pop.
  int? _popId;
  int _popCount = 0;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _reload();
  }

  @override
  void dispose() {
    _reviewTimer?.cancel();
    c.removeListener(_onChange);
    super.dispose();
  }

  bool _wasRunning = false;
  String? _shownError;

  void _onChange() {
    if (c.revision != _loadedRevision) _reload();
    if (c.running != _wasRunning || c.error != _shownError) {
      _wasRunning = c.running;
      _shownError = c.error;
      setState(() {});
    }
  }

  /// The review count needs every face compared, so it's worked out a moment
  /// after things settle instead of on every change.
  Timer? _reviewTimer;

  void _countReviewLater() {
    _reviewTimer?.cancel();
    _reviewTimer = Timer(const Duration(milliseconds: 900), () async {
      if (c.running) return;
      final n = (await c.reviewQueue()).length;
      if (mounted && n != _reviewCount) setState(() => _reviewCount = n);
    });
  }

  Future<void> _reload() async {
    _loadedRevision = c.revision;
    final trips = await c.db.trips();
    if (_tripId != null && !trips.any((t) => t.id == _tripId)) _tripId = null;
    final groups = await c.db.groups();
    if (_groupId != null && !groups.any((g) => g.id == _groupId)) _groupId = null;
    final people = await c.db.people(tripId: _tripId, dates: _dates, groupId: _groupId);
    _countReviewLater();
    if (!mounted) return;
    setState(() {
      _trips = trips;
      _groups = groups;
      _people = people;
    });
  }

  void _openScan() => Navigator.push(context,
      MaterialPageRoute(builder: (_) => ScanScreen(controller: c)));

  Future<void> _openPerson(PersonSummary p) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PersonScreen(
              controller: c, personId: p.id, tripId: _tripId, dates: _dates)),
    );
  }

  Future<void> _pickAlbumAndScan() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Photo access is needed to find faces.'),
        action: SnackBarAction(
            label: 'Settings', onPressed: PhotoManager.openSetting),
      ));
      return;
    }
    if (!mounted) return;
    final choice = await showScanSheet(context);
    if (choice == null || !mounted) return;
    final folder = choice.folder;
    if (folder != null) {
      final found = await c.scanFolder(folder);
      if (!mounted) return;
      if (found == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No photos in that folder. Pick another one.')));
        return;
      }
    } else {
      c.scan(choice.album!, dates: choice.dates);
    }
    _openScan();
  }

  Future<void> _dropMerge(PersonSummary dragged, PersonSummary target) async {
    if (dragged.id == target.id) return;
    Haptics.merge();
    // Keep whichever has a name, so the name survives.
    final (into, from) =
        target.name == null && dragged.name != null ? (dragged, target) : (target, dragged);
    final undo = await c.db.mergePeople(into.id, [from.id]);
    setState(() {
      _popId = into.id;
      _popCount++;
    });
    c.changed();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Merged into ${into.displayName}'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          await c.db.restore(undo);
          c.changed();
        },
      ),
    ));
  }

  Future<void> _editTrip(TripSummary trip) async {
    final text = TextEditingController(text: trip.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trip'),
        content: TextField(
          controller: text,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, '\u0000delete'),
            child: const Text('Remove trip'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, text.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    if (result == '\u0000delete') {
      await c.db.deleteTrip(trip.id);
    } else if (result.trim().isNotEmpty) {
      await c.db.renameTrip(trip.id, result);
    }
    c.changed();
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Scaffold places the button from the screen edge; lift it above the
      // floating dock (the extra bottom padding the root screen adds).
      floatingActionButton: Padding(
        padding: EdgeInsets.only(
          bottom: math.max(0, MediaQuery.paddingOf(context).bottom - MediaQuery.viewPaddingOf(context).bottom),
        ),
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => _ScanButton(
            controller: c,
            onStart: _pickAlbumAndScan,
            onOpen: _openScan,
          ),
        ).animate().scale(curve: Curves.easeOutBack, duration: 400.ms),
      ),
      body: GlassScrollView(
        title: 'People',
        actions: [
            if (people != null && people.isNotEmpty)
              _SearchButton(people: people, onOpen: _openPerson),
            // Always here, so a new scan is never hard to find.
            ListenableBuilder(
              listenable: c,
              builder: (context, _) => IconButton(
                tooltip: c.running ? 'Scan progress' : 'Scan photos',
                icon: Icon(c.running ? Icons.downloading_rounded : Icons.add_photo_alternate_outlined),
                onPressed: c.running ? _openScan : _pickAlbumAndScan,
              ),
            ),
            ListenableBuilder(
              listenable: c.sharing,
              builder: (context, _) => IconButton(
                tooltip: 'Sending',
                icon: Badge(
                  isLabelVisible: c.sharing.activeCount > 0,
                  label: Text('${c.sharing.activeCount}'),
                  child: const Icon(Icons.send_rounded),
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => SendCenterScreen(controller: c, tripId: _tripId)),
                ),
              ),
            ),
            _ReviewButton(
              count: _reviewCount,
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => ReviewScreen(controller: c))),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                switch (v) {
                  case 'together':
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => TogetherScreen(controller: c, tripId: _tripId)));
                  case 'cloud':
                    Haptics.tick();
                    setState(() => _cloud = !_cloud);
                  case 'settings':
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => SettingsScreen(controller: c)));
                }
              },
              itemBuilder: (_) => [
                if (people != null && people.length >= 2)
                  const PopupMenuItem(
                    value: 'together',
                    child: ListTile(leading: Icon(Icons.join_inner), title: Text('Photos together')),
                  ),
                if (people != null && people.isNotEmpty)
                  PopupMenuItem(
                    value: 'cloud',
                    child: ListTile(
                      leading: Icon(_cloud ? Icons.grid_view_rounded : Icons.bubble_chart_outlined),
                      title: Text(_cloud ? 'Grid view' : 'Bubble view'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(leading: Icon(Icons.tune), title: Text('Settings')),
                ),
              ],
            ),
          ],
        slivers: [
        if (_trips.isNotEmpty || (people?.isNotEmpty ?? false))
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: DateChip(
                      value: _dates,
                      onChanged: (d) {
                        _dates = d;
                        _reload();
                      },
                    ),
                  ),
                  _TripChip(
                    label: 'All trips',
                    selected: _tripId == null,
                    onTap: () {
                      _tripId = null;
                      _reload();
                    },
                  ),
                  for (final t in _trips)
                    _TripChip(
                      label: t.name,
                      count: t.photoCount,
                      selected: _tripId == t.id,
                      onTap: () {
                        _tripId = t.id;
                        _reload();
                      },
                      onLongPress: () => _editTrip(t),
                    ),
                ],
              ),
            ),
          ),
        if (people != null && (people.isNotEmpty || _groups.isNotEmpty))
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final g in _groups)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        onLongPress: () async {
                          if (await showGroupEditor(context, c, group: g)) c.changed();
                        },
                        child: ChoiceChip(
                          avatar: const Icon(Icons.diversity_3_outlined, size: 18),
                          label: Text('${g.name} · ${g.members.length}'),
                          selected: _groupId == g.id,
                          onSelected: (v) {
                            Haptics.tick();
                            _groupId = v ? g.id : null;
                            _reload();
                          },
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('New group'),
                      onPressed: () async {
                        if (await showGroupEditor(context, c)) c.changed();
                      },
                    ),
                  ),
                  if (_tripId != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ActionChip(
                        avatar: const Icon(Icons.timeline, size: 18),
                        label: const Text('Trip timeline'),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TimelineScreen(
                              controller: c,
                              tripId: _tripId!,
                              tripName: _trips.firstWhere((t) => t.id == _tripId).name,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_tripId != null && people != null)
          SliverToBoxAdapter(child: _MissingCard(people: people, onOpen: _openPerson)),
        if (c.running)
          SliverToBoxAdapter(
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) => _MiniProgress(controller: c, onTap: _openScan),
            ),
          ),
        if (c.error != null)
          SliverToBoxAdapter(
            child: MaterialBanner(
              content: Text('Scan stopped: ${c.error}'),
              actions: [
                TextButton(
                    onPressed: () => setState(() => c.error = null),
                    child: const Text('OK')),
              ],
            ),
          ),
        if (people == null)
          const SliverFillRemaining(child: PeopleSkeleton())
        else if (people.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyIllustration(
              message: c.running
                  ? 'People will appear here when the scan finishes.'
                  : 'Scan a trip album or folder to group photos by the people in them.\n'
                      'Everything stays on this phone.',
              action: c.running
                  ? null
                  : FilledButton.icon(
                      onPressed: _pickAlbumAndScan,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: const Text('Scan photos'),
                    ),
            ),
          )
        else if (_cloud)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, MediaQuery.paddingOf(context).bottom + _fabClearance),
            sliver: SliverToBoxAdapter(
              child: FaceCloud(people: people, onOpen: _openPerson),
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Long-press and drag one person onto another to merge them.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(12, 16, 12, MediaQuery.paddingOf(context).bottom + _fabClearance),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 120,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.72,
              ),
              itemCount: people.length,
              itemBuilder: (context, i) {
                final person = people[i];
                Widget tile = _PersonTile(
                  key: ValueKey(person.id),
                  person: person,
                  loadFaces: () async => [
                    for (final f in await c.db.facesOf(person.id, limit: 5)) f.thumb,
                  ],
                  onTap: () => _openPerson(person),
                  onMerge: (dragged) => _dropMerge(dragged, person),
                );
                if (person.id == _popId) {
                  tile = tile
                      .animate(key: ValueKey('pop$_popCount'))
                      .scaleXY(
                          begin: 1.3, end: 1, duration: 600.ms, curve: Curves.elasticOut);
                }
                // Pop in one after another the first time the grid appears.
                return tile
                    .animate(key: ValueKey('in${person.id}'))
                    .fadeIn(delay: (35 * i.clamp(0, 24)).ms, duration: 250.ms)
                    .scaleXY(
                        begin: 0.5,
                        delay: (35 * i.clamp(0, 24)).ms,
                        duration: 550.ms,
                        curve: Curves.elasticOut);
              },
            ),
          ),
        ],
      ]),
    );
  }
}

class _PersonTile extends StatefulWidget {
  const _PersonTile({
    super.key,
    required this.person,
    required this.loadFaces,
    required this.onTap,
    required this.onMerge,
  });

  final PersonSummary person;
  final Future<List<Uint8List>> Function() loadFaces;
  final VoidCallback onTap;
  final ValueChanged<PersonSummary> onMerge;

  @override
  State<_PersonTile> createState() => _PersonTileState();
}

/// Half the size of the drag feedback, to find the dragged face's centre.
const _feedbackHalf = Offset(50, 50);

class _PersonTileState extends State<_PersonTile> {
  bool _hovered = false;

  /// How far the face leans toward a person being dragged over it.
  Offset _pull = Offset.zero;
  int _ripples = 0;

  void _magnet(Offset feedbackTopLeft) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final centre = box.localToGlobal(Offset(box.size.width / 2, 47));
    final v = feedbackTopLeft + _feedbackHalf - centre;
    final len = v.distance;
    setState(() => _pull = len == 0 ? Offset.zero : v / len * (len * 0.3).clamp(0, 16));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final person = widget.person;
    final avatar = LivingAvatar(
      personId: person.id,
      cover: person.coverThumb,
      radius: 44,
      loadFaces: widget.loadFaces,
    );
    return DragTarget<PersonSummary>(
      onWillAcceptWithDetails: (d) {
        final ok = d.data.id != person.id;
        if (ok) Haptics.tick();
        setState(() => _hovered = ok);
        return ok;
      },
      onMove: (d) {
        if (_hovered) _magnet(d.offset);
      },
      onLeave: (_) => setState(() {
        _hovered = false;
        _pull = Offset.zero;
      }),
      onAcceptWithDetails: (d) {
        setState(() {
          _hovered = false;
          _pull = Offset.zero;
          _ripples++;
        });
        widget.onMerge(d.data);
      },
      builder: (context, _, _) => LongPressDraggable<PersonSummary>(
        data: person,
        hapticFeedbackOnStart: true,
        feedback: Material(
          type: MaterialType.transparency,
          child: Transform.scale(
            scale: 1.15,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 18)],
              ),
              child: FaceAvatar(
                  personId: person.id,
                  thumb: person.coverThumb,
                  radius: 44,
                  hero: false),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.25, child: _content(scheme, avatar)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          child: _content(scheme, avatar),
        ),
      ),
    );
  }

  Widget _content(ColorScheme scheme, Widget avatar) {
    final person = widget.person;
    return Column(children: [
      Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        // Ripple ring when someone is merged in.
        if (_ripples > 0)
          IgnorePointer(
            child: Container(
              width: 94,
              height: 94,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: scheme.primary, width: 3),
              ),
            )
                .animate(key: ValueKey(_ripples))
                .scaleXY(begin: 0.9, end: 1.7, duration: 700.ms, curve: Curves.easeOut)
                .fadeOut(duration: 700.ms),
          ),
        TweenAnimationBuilder<Offset>(
          tween: Tween(end: _pull),
          duration: 180.ms,
          curve: Curves.easeOut,
          builder: (_, pull, child) => Transform.translate(offset: pull, child: child),
          child: AnimatedScale(
            scale: _hovered ? 1.18 : 1,
            duration: 250.ms,
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: 250.ms,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hovered ? scheme.primary : Colors.transparent,
                boxShadow: _hovered
                    ? [BoxShadow(color: scheme.primary.withAlpha(120), blurRadius: 20)]
                    : const [],
              ),
              child: avatar,
            ),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
        person.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: person.name == null ? scheme.onSurfaceVariant : null,
        ),
      ),
      // Counts roll up from 0 when the grid first appears.
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: person.photoCount.toDouble()),
        duration: 900.ms,
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text('${v.round()} photos',
            style: Theme.of(context).textTheme.bodySmall),
      ),
    ]);
  }
}

/// "Scan album" button that shrinks into a filling progress ring while a
/// scan runs; tapping the ring opens the scan screen.
class _ScanButton extends StatelessWidget {
  const _ScanButton({
    required this.controller,
    required this.onStart,
    required this.onOpen,
  });

  final ScanController controller;
  final VoidCallback onStart;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: 350.ms,
      transitionBuilder: (child, a) => ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: child),
      child: c.running
          ? SizedBox.square(
              key: const ValueKey('ring'),
              dimension: 64,
              child: Stack(alignment: Alignment.center, children: [
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: c.total == 0 ? 0 : c.done / c.total),
                    duration: 400.ms,
                    builder: (_, v, _) => CircularProgressIndicator(
                      value: v,
                      strokeWidth: 5,
                      strokeCap: StrokeCap.round,
                      backgroundColor: scheme.primaryContainer,
                    ),
                  ),
                ),
                FloatingActionButton.small(
                  heroTag: null,
                  elevation: 0,
                  onPressed: onOpen,
                  child: const Icon(Icons.face_retouching_natural),
                )
                    .animate(onPlay: (a) => a.repeat(reverse: true))
                    .scaleXY(end: 1.08, duration: 900.ms, curve: Curves.easeInOut),
              ]),
            )
          : FloatingActionButton.extended(
              key: const ValueKey('start'),
              heroTag: null,
              onPressed: onStart,
              icon: const Icon(Icons.face_retouching_natural),
              label: const Text('Scan album'),
            ),
    );
  }
}

class _TripChip extends StatelessWidget {
  const _TripChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.onLongPress,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ChoiceChip(
          avatar: count == null ? null : const Icon(Icons.luggage_outlined, size: 18),
          label: Text(count == null ? label : '$label · $count'),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      ),
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.controller, required this.onTap});

  final ScanController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              SizedBox.square(
                dimension: 44,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: c.total == 0 ? 0 : c.done / c.total),
                  duration: 400.ms,
                  builder: (_, v, _) => CircularProgressIndicator(
                      value: v, strokeWidth: 5, strokeCap: StrokeCap.round),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Scanning ${c.albumName ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${c.done} of ${c.total} · ${c.facesFound} faces'),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ),
      ),
    ).animate().fadeIn().moveY(begin: -10);
  }
}

class _ReviewButton extends StatelessWidget {
  const _ReviewButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Review faces',
      onPressed: onTap,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text(count > 99 ? '99+' : '$count'),
        child: const Icon(Icons.swipe_outlined),
      )
          .animate(key: ValueKey(count > 0), target: count > 0 ? 1 : 0)
          .shake(hz: 3, duration: 600.ms),
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.people, required this.onOpen});

  final List<PersonSummary> people;
  final ValueChanged<PersonSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    return SearchAnchor(
      viewHintText: 'Search people',
      builder: (context, search) => IconButton(
        tooltip: 'Search',
        icon: const Icon(Icons.search),
        onPressed: search.openView,
      ),
      suggestionsBuilder: (context, search) {
        final q = search.text.trim().toLowerCase();
        final matches = people
            .where((p) =>
                (p.name?.toLowerCase().contains(q) ?? false) ||
                (p.nickname?.toLowerCase().contains(q) ?? false))
            .toList();
        if (matches.isEmpty) {
          return [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No named person matches')),
            ),
          ];
        }
        return [
          for (final p in matches)
            ListTile(
              leading: FaceAvatar(
                  personId: p.id, thumb: p.coverThumb, radius: 22, hero: false),
              title: Text(p.displayName),
              subtitle: Text(p.nickname == null
                  ? '${p.photoCount} photos'
                  : '"${p.nickname}" · ${p.photoCount} photos'),
              onTap: () {
                search.closeView(p.displayName);
                onOpen(p);
              },
            ),
        ];
      },
    );
  }
}

/// "Who's missing": named people with very few photos in this trip, so you
/// can take more of them tomorrow.
class _MissingCard extends StatelessWidget {
  const _MissingCard({required this.people, required this.onOpen});

  final List<PersonSummary> people;
  final ValueChanged<PersonSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    final named = [for (final p in people) if (p.name != null) p];
    if (named.length < 3) return const SizedBox.shrink();
    final counts = [for (final p in named) p.photoCount]..sort();
    final median = counts[counts.length ~/ 2];
    final few = [
      for (final p in named)
        if (p.photoCount < (median * 0.35).clamp(3, 1 << 30)) p,
    ]..sort((a, b) => a.photoCount.compareTo(b.photoCount));
    if (few.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        color: scheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.person_search_outlined, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Text('Needs more photos',
                  style: TextStyle(
                      color: scheme.onTertiaryContainer, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 64,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final p in few)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => onOpen(p),
                      child: Column(children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundImage:
                              p.coverThumb == null ? null : MemoryImage(p.coverThumb!),
                        ),
                        const SizedBox(height: 4),
                        Text('${p.displayName.split(' ').first} · ${p.photoCount}',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onTertiaryContainer)),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ).animate().fadeIn().moveY(begin: -6);
  }
}
