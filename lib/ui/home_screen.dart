import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/db.dart';
import '../data/trip_days.dart';
import '../scan/scan_controller.dart';
import 'face_cloud.dart';
import 'find_me_screen.dart';
import 'glass.dart';
import 'group_editor.dart';
import 'motion.dart';
import 'people_space.dart';
import 'person_screen.dart';
import 'review_screen.dart';
import 'scan_screen.dart';
import 'scan_sheet.dart';
import 'search_screen.dart';
import 'sections.dart';
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

  /// The selected trip's days, for the day chips.
  List<TripDay> _days = const [];
  int _reviewCount = 0;
  int? _tripId;
  DaySpan? _dates;
  List<PersonGroup> _groups = const [];
  int? _groupId;
  int _loadedRevision = -1;

  /// Floating bubble view instead of the grid.
  /// Grid, bubbles or one of the spatial views; remembered.
  PeopleLayout _layout = PeopleLayout.grid;

  /// Person that just absorbed a drag-merge; plays a pop.
  int? _popId;
  int _popCount = 0;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _reload();
    c.db.setting(_layoutKey).then((v) {
      if (mounted) setState(() => _layout = PeopleLayout.byName(v));
    });
  }

  static const _layoutKey = 'people_layout';

  void _setLayout(PeopleLayout l) {
    if (l == _layout) return;
    Haptics.tick();
    setState(() => _layout = l);
    c.db.setSetting(_layoutKey, l.name);
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
    final days = _tripId == null ? const <TripDay>[] : await tripDays(c.db, _tripId!);
    _countReviewLater();
    if (!mounted) return;
    setState(() {
      _days = days;
      _trips = trips;
      _groups = groups;
      _people = people;
    });
  }

  /// Picking another trip drops a day picked from the old one.
  void _pickTrip(int? id) {
    if (_days.any((d) => d.span == _dates)) _dates = null;
    _tripId = id;
    _reload();
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
        physics: people != null && people.isNotEmpty && _layout.spatial ? const NeverScrollableScrollPhysics() : null,
        subtitle: people == null || people.isEmpty ? null : '${people.length} ${people.length == 1 ? 'person' : 'people'}',
        actions: [
          ToolbarCapsule(children: [
            if (people != null && people.isNotEmpty)
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search_rounded),
                onPressed: () => Navigator.push(
                    context, MaterialPageRoute(builder: (_) => SearchScreen(controller: c))),
              ),
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
                  case 'findme':
                    final trip = _trips.where((t) => t.id == _tripId).firstOrNull;
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => FindMeScreen(controller: c, tripId: trip?.id, tripName: trip?.name)));
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
                  const PopupMenuItem(
                    value: 'findme',
                    child: ListTile(
                        leading: Icon(Icons.face_retouching_natural_rounded), title: Text('Find my photos link')),
                  ),
                const PopupMenuItem(
                  value: 'settings',
                  child: ListTile(leading: Icon(Icons.tune), title: Text('Settings')),
                ),
              ],
            ),
          ]),
        ],
        slivers: [
        if (_trips.isNotEmpty || (people?.isNotEmpty ?? false))
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
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
                    onTap: () => _pickTrip(null),
                  ),
                  for (final t in _trips)
                    _TripChip(
                      label: t.name,
                      count: t.photoCount,
                      selected: _tripId == t.id,
                      onTap: () => _pickTrip(t.id),
                      onLongPress: () => _editTrip(t),
                    ),
                ],
              ),
            ),
          ),
        if (_tripId != null && _days.length > 1)
          // The fade goes on the row, not the sliver: effects are boxes, and
          // a box can't hold a sliver (the whole page went blank).
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final d in _days)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: CapsuleChip(
                          icon: Icons.today_rounded,
                          label: d.label,
                          count: d.photos.length,
                          selected: _dates == d.span,
                          onTap: () {
                            Haptics.tick();
                            _dates = _dates == d.span ? null : d.span;
                            _reload();
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ).animate(key: ValueKey(_tripId)).fadeIn(duration: 250.ms).moveY(begin: -6),
          ),
        if (people != null && (people.isNotEmpty || _groups.isNotEmpty))
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final g in _groups)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: CapsuleChip(
                          icon: Icons.diversity_3_rounded,
                          label: g.name,
                          count: g.members.length,
                          selected: _groupId == g.id,
                          onTap: () {
                            Haptics.tick();
                            _groupId = _groupId == g.id ? null : g.id;
                            _reload();
                          },
                          onLongPress: () async {
                            if (await showGroupEditor(context, c, group: g)) c.changed();
                          },
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Center(
                      child: CapsuleChip(
                        outlined: true,
                        icon: Icons.add_rounded,
                        label: 'New group',
                        onTap: () async {
                          if (await showGroupEditor(context, c)) c.changed();
                        },
                      ),
                    ),
                  ),
                  if (_tripId != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: CapsuleChip(
                        outlined: true,
                        icon: Icons.timeline_rounded,
                        label: 'Trip timeline',
                        onTap: () => Navigator.push(
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
                    ),
                ],
              ),
            ),
          ),
        if (people != null && people.isNotEmpty)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final l in PeopleLayout.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: CapsuleChip(
                          icon: l.icon,
                          label: l.label,
                          selected: _layout == l,
                          onTap: () => _setLayout(l),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_tripId != null && people != null && !_layout.spatial)
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
        else if (_layout.spatial)
          SliverFillRemaining(
            child: PeopleSpace(
              people: people,
              layout: _layout,
              onOpen: _openPerson,
              hubLabel: _tripId == null ? null : _trips.firstWhere((t) => t.id == _tripId).name,
            ),
          )
        else if (_layout == PeopleLayout.bubbles)
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
                color: _hovered || person.name != null ? scheme.primary : scheme.onSurface.withAlpha(45),
                boxShadow: _hovered ? [BoxShadow(color: scheme.primary.withAlpha(70), spreadRadius: 5)] : const [],
              ),
              child: avatar,
            ),
          ),
        ),
      ]),
      const SizedBox(height: 7),
      Text(
        person.name ?? 'Add a name',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14.5,
          fontWeight: person.name == null ? FontWeight.w600 : FontWeight.w700,
          color: person.name == null ? scheme.primary : null,
        ),
      ),
      // Counts roll up from 0 when the grid first appears.
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: person.photoCount.toDouble()),
        duration: 900.ms,
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text('${v.round()} photos',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  shape: const CircleBorder(),
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
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              elevation: 3,
              shape: const StadiumBorder(),
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
      child: Center(
        child: CapsuleChip(
          icon: count == null ? null : Icons.luggage_rounded,
          label: label,
          count: count,
          selected: selected,
          onTap: onTap,
          onLongPress: onLongPress,
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
      child: SectionCard(
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
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text('${c.done} of ${c.total} · ${c.facesFound} faces',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
      child: SectionCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              IconTile(icon: Icons.person_search_rounded, color: Color(0xFFFF9F0A)),
              SizedBox(width: 12),
              Text('Needs more photos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
