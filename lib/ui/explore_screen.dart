import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'anim.dart';

import '../data/db.dart';
import '../face/tags.dart';
import '../scan/scan_controller.dart';
import '../data/duplicates.dart';
import '../data/group_shots.dart';
import 'best_shots_screen.dart';
import 'desktop_layout.dart';
import 'face_image.dart';
import 'duplicates_screen.dart';
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'places_screen.dart';
import 'sections.dart';
import 'storage_screen.dart';
import 'theme.dart';
import 'together_screen.dart';
import 'widgets.dart';

typedef _Meta = (String title, IconData icon);

const _people = <String, _Meta>{
  'selfie': ('Selfies', Icons.camera_front_outlined),
  'solo': ('Solo', Icons.person_outline),
  'couple': ('Two people', Icons.people_outline),
  'group': ('Groups', Icons.groups_outlined),
  'smiling': ('Smiles', Icons.sentiment_very_satisfied_outlined),
  'no_people': ('No people', Icons.landscape_outlined),
};

const _types = <String, _Meta>{
  'screenshot': ('Screenshots', Icons.screenshot_outlined),
  'whatsapp': ('WhatsApp', Icons.chat_outlined),
  'telegram': ('Telegram', Icons.send_outlined),
  'download': ('Downloads', Icons.download_outlined),
  'location': ('With location', Icons.place_outlined),
  'portrait': ('Portrait', Icons.crop_portrait),
  'landscape': ('Landscape', Icons.crop_landscape),
  'blurry': ('Blurry', Icons.blur_on),
  'eyes_closed': ('Eyes closed', Icons.visibility_off_outlined),
  'looking_away': ('Looking away', Icons.turn_slight_left),
};

/// Icons for common ML Kit labels; anything else gets a generic one.
const _labelIcons = <String, IconData>{
  'Food': Icons.restaurant_outlined,
  'Dog': Icons.pets_outlined,
  'Cat': Icons.pets_outlined,
  'Pet': Icons.pets_outlined,
  'Beach': Icons.beach_access_outlined,
  'Sky': Icons.cloud_outlined,
  'Cloud': Icons.cloud_outlined,
  'Sunset': Icons.wb_twilight_outlined,
  'Flower': Icons.local_florist_outlined,
  'Plant': Icons.eco_outlined,
  'Tree': Icons.park_outlined,
  'Mountain': Icons.terrain_outlined,
  'Lake': Icons.water_outlined,
  'River': Icons.water_outlined,
  'Car': Icons.directions_car_outlined,
  'Building': Icons.apartment_outlined,
  'Skyscraper': Icons.apartment_outlined,
  'Bridge': Icons.foundation_outlined,
  'Snow': Icons.ac_unit_outlined,
  'Cake': Icons.cake_outlined,
  'Party': Icons.celebration_outlined,
  'Smile': Icons.sentiment_satisfied_outlined,
};

/// Scene labels with fewer photos than this aren't worth a card.
const _minSceneCount = 2;

/// Photos sorted into categories found during scanning.
class ExploreTab extends StatefulWidget {
  const ExploreTab({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<ExploreTab> {
  ScanController get c => widget.controller;
  DaySpan? _dates;
  Map<String, ({int count, String cover})>? _counts;
  List<DuplicateSet> _dupes = const [];
  List<ShotBurst> _bursts = const [];

  /// Photos with a location, for the Places map.
  int _located = 0;

  /// Desktop cards: a few photos with a location, and the people who are
  /// most often in photos (for "Together").
  List<String> _placeCovers = const [];
  List<PersonSummary> _people2 = const [];
  int _loadedRevision = -1;

  /// One scroll controller per row, for the parallax effect.
  final Map<String, ScrollController> _rowScroll = {};

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    for (final s in _rowScroll.values) {
      s.dispose();
    }
    super.dispose();
  }

  void _onChange() {
    if (c.revision != _loadedRevision && !c.running) _load();
  }

  Future<void> _load() async {
    _loadedRevision = c.revision;
    final counts = await c.db.tagCounts(dates: _dates);
    final dupes = findDuplicates(await c.db.fingerprints())
        .where((d) => !d.allExtrasHidden)
        .toList();
    final bursts = findBursts(await c.db.groupShots());
    final located = await c.db.locatedCount();
    var placeCovers = const <String>[];
    var people = const <PersonSummary>[];
    if (DesktopLayout.on) {
      final where = await c.db.photoLocations(dates: _dates);
      placeCovers = [for (final p in where.reversed.take(5)) p.id];
      people = [for (final p in await c.db.people()) if (p.name != null) p];
    }
    if (mounted) {
      setState(() {
        _located = located;
        _placeCovers = placeCovers;
        _people2 = people;
        _counts = counts;
        _dupes = dupes;
        _bursts = bursts;
      });
    }
  }

  void _open(String tag, String title, String cover) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TagScreen(
            controller: c, tag: tag, title: title, cover: cover, dates: _dates),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassScrollView(
        title: 'Explore',
        subtitle: DesktopLayout.on && counts != null && counts.isNotEmpty
            ? 'Sorted into ${counts.length} ${counts.length == 1 ? 'category' : 'categories'} while scanning'
            : null,
        actions: [
            DateChip(
              value: _dates,
              onChanged: (d) {
                _dates = d;
                _load();
              },
            ),
            const SizedBox(width: 12),
          ],
        slivers: [
        if (counts == null)
          SliverToBoxAdapter(
            child: Column(children: [
              for (var r = 0; r < 3; r++)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Skeleton(width: 120, height: 16, radius: 8),
                    const SizedBox(height: 12),
                    Row(children: [
                      for (var k = 0; k < 3; k++) ...[
                        if (k > 0) const SizedBox(width: _cardGap),
                        const Skeleton(width: _cardWidth, height: 170, radius: 22),
                      ],
                    ]),
                  ]),
                ),
            ]),
          )
        else if (counts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyIllustration(
              message: _dates == null
                  ? 'Scan an album and your photos will be sorted here into '
                      'Selfies, Groups, Food, Beach, Screenshots and more.'
                  : 'No scanned photos in these dates.',
            ),
          )
        else if (DesktopLayout.on) ...[
          SliverToBoxAdapter(child: _deskFeatures(context)),
          ..._deskSection(context, 'People', [
            for (final e in _people.entries)
              if (counts[e.key] != null) (e.key, e.value.$1, e.value.$2, counts[e.key]!),
          ]),
          ..._deskSection(context, 'Photo types', [
            for (final e in _types.entries)
              if (counts[e.key] != null) (e.key, e.value.$1, e.value.$2, counts[e.key]!),
          ]),
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ]
        else ...[
            // Places is always here, so the map is easy to find.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SectionCard.rows(rows: [
                    SectionRow(
                      leading: const IconTile(icon: Icons.map_rounded, color: Color(0xFF34C759)),
                      title: 'Places',
                      subtitle: _located > 0
                          ? '$_located photos on the map'
                          : 'Your photos by where they were taken',

                      chevron: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => PlacesScreen(controller: c)),
                      ).then((_) => _load()),
                    ),
                  if (_bursts.isNotEmpty)
                    SectionRow(
                      leading: const IconTile(icon: Icons.auto_awesome_rounded, color: Color(0xFFFF9F0A)),
                      title: 'Best group shots',
                      subtitle: '${_bursts.length} ${_bursts.length == 1 ? 'moment' : 'moments'} · '
                          'everyone\'s eyes open',
                      chevron: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => BestShotsScreen(controller: c)),
                      ).then((_) => _load()),
                    ),
                  if (_dupes.isNotEmpty)
                    SectionRow(
                      leading: const IconTile(icon: Icons.auto_delete_rounded, color: Color(0xFF5E5CE6)),
                      title: 'Clean up duplicates',
                      subtitle: '${_dupes.length} sets · '
                          '${_dupes.fold<int>(0, (n, d) => n + d.photos.length - 1)} extra photos',
                      chevron: true,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => DuplicatesScreen(controller: c)),
                      ).then((_) => _load()),
                    ),
                ]),
              ).animate().fadeIn().moveY(begin: -8),
            ),
          ..._section(context, 'People', [
            for (final e in _people.entries)
              if (counts[e.key] != null)
                (e.key, e.value.$1, e.value.$2, counts[e.key]!),
          ]),
          ..._section(context, 'Places & things', [
            for (final e in (counts.entries
                    .where((e) =>
                        e.key.startsWith(labelPrefix) &&
                        e.value.count >= _minSceneCount)
                    .toList()
                  ..sort((a, b) => b.value.count.compareTo(a.value.count))))
              (
                e.key,
                e.key.substring(labelPrefix.length),
                _labelIcons[e.key.substring(labelPrefix.length)] ??
                    Icons.label_outline,
                e.value,
              ),
          ]),
          ..._section(context, 'Photo types', [
            for (final e in _types.entries)
              if (counts[e.key] != null)
                (e.key, e.value.$1, e.value.$2, counts[e.key]!),
          ]),
          SliverPadding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 16)),
        ],
      ]),
    );
  }

  void _push(Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen)).then((_) => _load());

  /// Desktop, like a photo library's "For You": Places as a wide banner of
  /// photos, then the app's tools as an even row of tiles, each with its
  /// number and a few of its photos. Tools with nothing to show are left out.
  Widget _deskFeatures(BuildContext context) {
    final extra = _dupes.fold<int>(0, (n, d) => n + d.photos.length - 1);
    final tools = <Widget>[
      if (_bursts.isNotEmpty)
        _ToolTile(
          icon: Icons.auto_awesome_rounded,
          color: const Color(0xFFFF9F0A),
          title: 'Best group shots',
          value: '${_bursts.length}',
          unit: _bursts.length == 1 ? 'moment' : 'moments',
          photos: [for (final b in _bursts.take(3)) b.bestShot.shot.assetId],
          onTap: () => _push(BestShotsScreen(controller: c)),
        ),
      if (_dupes.isNotEmpty)
        _ToolTile(
          icon: Icons.filter_none_rounded,
          color: const Color(0xFF0A84FF),
          title: 'Duplicates',
          value: '$extra',
          unit: extra == 1 ? 'extra copy' : 'extra copies',
          photos: [for (final p in _dupes.first.photos.take(3)) p.assetId],
          onTap: () => _push(DuplicatesScreen(controller: c)),
        ),
      if (_people2.length >= 2)
        _ToolTile(
          icon: Icons.favorite_rounded,
          color: const Color(0xFFFF2D55),
          title: 'Together',
          value: '${_people2.length}',
          unit: 'people to pair up',
          faces: [for (final p in _people2.take(5)) ?p.coverThumb],
          onTap: () => _push(TogetherScreen(controller: c)),
        ),
      _ToolTile(
        icon: Icons.pie_chart_rounded,
        color: const Color(0xFF8E8E93),
        title: 'Storage',
        unit: 'What takes up the most space',
        onTap: () => _push(StorageScreen(controller: c)),
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      const gap = 14.0, pad = 24.0;
      final width = box.maxWidth - 2 * pad;
      final columns = width >= 900 ? 4 : 2;
      final cell = (width - (columns - 1) * gap) / columns;
      return Padding(
        padding: const EdgeInsets.fromLTRB(pad, 4, pad, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _PlacesBanner(
            covers: _placeCovers,
            located: _located,
            onOpen: () => _push(PlacesScreen(controller: c)),
          ).animate().fadeIn(duration: 250.ms).moveY(begin: 6, curve: Curves.easeOutCubic),
          const SizedBox(height: 14),
          Wrap(spacing: gap, runSpacing: gap, children: [
            for (final (i, t) in tools.indexed)
              SizedBox(width: cell, height: 150, child: t)
                  .animate()
                  .fadeIn(delay: (50 + 40 * i).ms, duration: 220.ms)
                  .moveY(begin: 6, curve: Curves.easeOutCubic),
          ]),
        ]),
      );
    });
  }

  /// Desktop: a category section as a wrapping grid of cards (a mouse can't
  /// swipe the phone's sideways rows).
  List<Widget> _deskSection(
    BuildContext context,
    String title,
    List<(String, String, IconData, ({int count, String cover}))> cards,
  ) {
    if (cards.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 28, 24, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('${cards.length}', style: TextStyle(fontSize: TextSize.small, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisExtent: 214,
            mainAxisSpacing: 18,
            crossAxisSpacing: 16,
          ),
          itemCount: cards.length,
          itemBuilder: (context, i) {
            final (tag, name, icon, info) = cards[i];
            return _AlbumTile(
              key: ValueKey('$tag$_dates'),
              title: name,
              icon: icon,
              count: info.count,
              cover: info.cover,
              tag: tag,
              loadCovers: () => c.db.tagCovers(tag, dates: _dates, limit: 9),
              index: i,
              onTap: (cover) => _open(tag, name, cover),
            ).animate().fadeIn(delay: (30 * i.clamp(0, 12)).ms, duration: 220.ms);
          },
        ),
      ),
    ];
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    List<(String, String, IconData, ({int count, String cover}))> cards,
  ) {
    if (cards.isEmpty) return const [];
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
          child: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 170,
          child: ListView.separated(
            controller: _rowScroll.putIfAbsent(title, ScrollController.new),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: _rowPad),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: _cardGap),
            itemBuilder: (context, i) {
              final (tag, name, icon, info) = cards[i];
              return _CategoryCard(
                key: ValueKey('$tag$_dates'),
                title: name,
                icon: icon,
                count: info.count,
                cover: info.cover,
                tag: tag,
                loadCovers: () => c.db.tagCovers(tag, dates: _dates, limit: 9),
                scroll: _rowScroll[title]!,
                index: i,
                onTap: (cover) => _open(tag, name, cover),
              )
                  .animate()
                  .fadeIn(delay: (40 * i.clamp(0, 10)).ms)
                  .scaleXY(begin: 0.85, curve: Curves.easeOutBack, duration: 450.ms);
            },
          ),
        ),
      ),
    ];
  }
}

const _cardWidth = 140.0;
const _cardGap = 12.0;
const _rowPad = 16.0;

/// Category card whose cover slowly cross-fades between a few of its photos
/// with a gentle zoom, and shifts against the row's scroll (parallax).
class _CategoryCard extends StatefulWidget {
  const _CategoryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.count,
    required this.cover,
    required this.loadCovers,
    required this.scroll,
    required this.index,
    required this.onTap,
    required this.tag,
  });

  final String tag;

  final String title;
  final IconData icon;
  final int count;
  final String cover;
  final Future<List<String>> Function() loadCovers;

  /// The sideways row it's in, for the parallax; null in a grid (desktop),
  /// where the card also fills its cell.
  final ScrollController? scroll;
  final int index;
  /// Called with the cover showing at the moment of the tap.
  final ValueChanged<String> onTap;

  @override
  State<_CategoryCard> createState() => _CategoryCardState();
}

class _CategoryCardState extends State<_CategoryCard>
    with SingleTickerProviderStateMixin {
  late List<String> _covers = [widget.cover];

  /// Up to 9 photos for the mosaic on the back of the card.
  List<String> _mosaic = const [];
  int _i = 0;
  Timer? _timer;
  ValueListenable<TickerModeData>? _active;

  /// Long-press flips the card over to a 3×3 mosaic, and back.
  late final AnimationController _flip =
      AnimationController(vsync: this, duration: 550.ms);

  void _toggleFlip() {
    Haptics.lift();
    _flip.status == AnimationStatus.completed || _flip.status == AnimationStatus.forward
        ? _flip.reverse()
        : _flip.forward();
  }

  @override
  void initState() {
    super.initState();
    widget.loadCovers().then((all) {
      if (!mounted) return;
      setState(() => _mosaic = all);
      final ids = all.take(4).toList();
      if (ids.length < 2) return;
      _covers = ids;
      final period = Duration(milliseconds: 4000 + 700 * (widget.index % 4));
      _timer = Timer.periodic(period, (_) {
        if (mounted && (_active?.value.enabled ?? true)) {
          setState(() => _i = (_i + 1) % _covers.length);
        }
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.getValuesNotifier(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.scroll == null ? null : _cardWidth,
      child: AnimatedBuilder(
        animation: _flip,
        builder: (context, _) {
          final angle = Curves.easeInOutBack.transform(_flip.value) * math.pi;
          final back = angle > math.pi / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..rotateY(angle),
            child: back
                ? Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.rotationY(math.pi),
                    child: _back(),
                  )
                : _front(),
          );
        },
      ),
    );
  }

  Widget _back() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(DesktopLayout.on ? Mac.cardRadius : 22),
      child: GestureDetector(
        onTap: () => widget.onTap(_covers[_i]),
        onLongPress: _toggleFlip,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: GridView.count(
            crossAxisCount: 3,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            childAspectRatio: _cardWidth / 170,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final (k, id) in _mosaic.indexed)
                AssetThumb(id: id, size: 120)
                    .animate()
                    .fadeIn(delay: (40 * k).ms)
                    .scaleXY(begin: 0.7, curve: Curves.easeOutBack),
            ],
          ),
        ),
      ),
    );
  }

  Widget _front() {
    final screen = MediaQuery.sizeOf(context).width;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The cover on top, the name and count underneath on a quiet card.
    final desk = DesktopLayout.on;
    return ClipRRect(
      borderRadius: BorderRadius.circular(desk ? Mac.cardRadius : 22),
      child: Material(
        color: desk ? Mac.card(context) : dark ? const Color(0xC71C1C1F) : const Color(0xD9FFFFFF),
        shape: desk
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Mac.cardRadius),
                side: BorderSide(color: Mac.hairline(context), width: 0.5),
              )
            : null,
        child: InkWell(
          onTap: () => widget.onTap(_covers[_i]),
          onLongPress: _toggleFlip,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                ClipRect(
                  child: AnimatedBuilder(
                    // Parallax: the image drifts opposite to the row's scroll.
                    animation: widget.scroll ?? const AlwaysStoppedAnimation(0),
                    builder: (context, child) {
                      final scroll = widget.scroll;
                      if (scroll == null) return child!;
                      final offset = scroll.hasClients ? scroll.offset : 0.0;
                      final centre = _rowPad + widget.index * (_cardWidth + _cardGap) + _cardWidth / 2 - offset;
                      final shift = ((centre - screen / 2) / screen).clamp(-1.0, 1.0) * -22;
                      return Transform.translate(offset: Offset(shift, 0), child: child);
                    },
                    child: Hero(
                      // Flies into the category page's header when opened.
                      tag: 'cat-${widget.tag}',
                      child: Transform.scale(
                        scale: 1.35,
                        child: AnimatedSwitcher(
                          duration: 900.ms,
                          child: KeyedSubtree(
                            key: ValueKey(_covers[_i]),
                            child: AssetThumb(id: _covers[_i], size: 300)
                                .animate()
                                .scaleXY(begin: 1, end: 1.12, duration: 5000.ms),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: Colors.black.withAlpha(80), borderRadius: BorderRadius.circular(10)),
                    child: Icon(widget.icon, color: Colors.white, size: 18),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: TextSize.callout)),
                Text('${widget.count} photos', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: TextSize.small)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// All photos in one category, by day.
class TagScreen extends StatefulWidget {
  const TagScreen({
    super.key,
    required this.controller,
    required this.tag,
    required this.title,
    required this.cover,
    this.dates,
  });

  final ScanController controller;
  final String tag;
  final String title;

  /// The photo the card was showing; becomes the page's header.
  final String cover;
  final DaySpan? dates;

  @override
  State<TagScreen> createState() => _TagScreenState();
}

class _TagScreenState extends State<TagScreen> {
  late DaySpan? _dates = widget.dates;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          DateChip(value: _dates, onChanged: (d) => setState(() => _dates = d)),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(children: [
        SizedBox(
          height: 150,
          width: double.infinity,
          child: Stack(fit: StackFit.expand, children: [
            Hero(
              tag: 'cat-${widget.tag}',
              child: AssetThumb(id: widget.cover, size: 800),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 20,
              bottom: 14,
              child: Row(children: [
                Icon(categoryIcon(widget.tag), color: Colors.white),
                const SizedBox(width: 8),
                Text(widget.title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: TextSize.title2, fontWeight: FontWeight.w800)),
              ]).animate().fadeIn(delay: 200.ms).moveX(begin: -12),
            ),
          ]),
        ),
        Expanded(
          child: GalleryView(
            key: ValueKey(_dates),
            controller: widget.controller,
            source: GallerySource.ids(
                () => widget.controller.db.photosWithTag(widget.tag, dates: _dates)),
            emptyMessage: 'No photos in this category for these dates.',
          ),
        ),
      ]),
    );
  }
}

/// Display name for any stored tag.
String categoryTitle(String tag) =>
    _people[tag]?.$1 ??
    _types[tag]?.$1 ??
    (tag.startsWith(labelPrefix) ? tag.substring(labelPrefix.length) : tag);

/// The built-in categories (not scene labels), tag -> title.
Map<String, String> get builtInCategories => {
      for (final e in {..._people, ..._types}.entries) e.key: e.value.$1,
    };

IconData categoryIcon(String tag) =>
    _people[tag]?.$2 ??
    _types[tag]?.$2 ??
    _labelIcons[tag.startsWith(labelPrefix) ? tag.substring(labelPrefix.length) : tag] ??
    Icons.label_outline;

/// Desktop Explore: Places as a wide banner, a collage of photos taken
/// somewhere known, with the count and Open map.
class _PlacesBanner extends StatefulWidget {
  const _PlacesBanner({required this.covers, required this.located, required this.onOpen});

  final List<String> covers;
  final int located;
  final VoidCallback onOpen;

  @override
  State<_PlacesBanner> createState() => _PlacesBannerState();
}

class _PlacesBannerState extends State<_PlacesBanner> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.covers;
    Widget photo(int i) => i < c.length
        ? AnimatedScale(
            scale: _hover ? 1.03 : 1,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            child: AssetThumb(id: c[i], size: 600),
          )
        : ColoredBox(color: scheme.surfaceContainerHighest);
    final Widget collage = c.isEmpty
        ? ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Center(child: Icon(Icons.map_rounded, size: 56, color: scheme.onSurfaceVariant.withValues(alpha: 0.5))),
          )
        : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 3, child: ClipRect(child: photo(0))),
            if (c.length > 1) ...[
              const SizedBox(width: 3),
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: ClipRect(child: photo(1))),
                      const SizedBox(width: 3),
                      Expanded(child: ClipRect(child: photo(2))),
                    ]),
                  ),
                  const SizedBox(height: 3),
                  Expanded(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: ClipRect(child: photo(3))),
                      const SizedBox(width: 3),
                      Expanded(child: ClipRect(child: photo(4))),
                    ]),
                  ),
                ]),
              ),
            ],
          ]);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 230,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Mac.hairline(context), width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _hover ? 0.18 : 0.06),
                blurRadius: _hover ? 18 : 4,
                offset: Offset(0, _hover ? 6 : 1),
              ),
            ],
          ),
          child: Stack(fit: StackFit.expand, children: [
            collage,
            Positioned(
              left: 14,
              bottom: 14,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: const Color(0xFF2BB5A6), borderRadius: BorderRadius.circular(9)),
                    child: const Icon(Icons.map_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    const Text('Places',
                        style: TextStyle(color: Colors.white, fontSize: TextSize.headline, fontWeight: FontWeight.w700)),
                    Text(
                      widget.located > 0 ? '${widget.located} photos on the map' : 'Your photos by where they were taken',
                      style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: TextSize.small),
                    ),
                  ]),
                  const SizedBox(width: 18),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    onPressed: widget.onOpen,
                    child: const Text('Open map'),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Desktop Explore: one tool (Best group shots, Duplicates…): its icon,
/// name, a big number and a strip of its photos or faces.
class _ToolTile extends StatefulWidget {
  const _ToolTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.unit,
    required this.onTap,
    this.value,
    this.photos = const [],
    this.faces = const [],
  });

  final IconData icon;
  final Color color;
  final String title, unit;
  final String? value;
  final VoidCallback onTap;
  final List<String> photos;
  final List<Uint8List> faces;

  @override
  State<_ToolTile> createState() => _ToolTileState();
}

class _ToolTileState extends State<_ToolTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final scheme = Theme.of(context).colorScheme;
    Widget strip;
    if (w.photos.isNotEmpty) {
      strip = Row(children: [
        for (final (i, id) in w.photos.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(6), child: AssetThumb(id: id, size: 160))),
        ],
      ]);
    } else if (w.faces.isNotEmpty) {
      strip = Row(children: [
        for (final (i, f) in w.faces.indexed)
          Align(
            widthFactor: 0.72,
            child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Mac.card(context), width: 2)),
              child: CircleAvatar(radius: 18, backgroundImage: FaceImage(f)),
            ),
          ).animate().fadeIn(delay: (40 * i).ms),
      ]);
    } else {
      strip = Align(
        alignment: Alignment.centerLeft,
        child: Text(w.unit, style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: w.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Mac.card(context),
            borderRadius: BorderRadius.circular(Mac.cardRadius),
            border: Border.all(color: _hover ? w.color.withValues(alpha: 0.5) : Mac.hairline(context), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _hover ? 0.12 : 0.03),
                blurRadius: _hover ? 14 : 3,
                offset: Offset(0, _hover ? 5 : 1),
              ),
            ],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: w.color, borderRadius: BorderRadius.circular(7)),
                child: Icon(w.icon, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(w.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w600)),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant.withValues(alpha: _hover ? 1 : 0.5)),
            ]),
            const SizedBox(height: 8),
            if (w.value != null)
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(w.value!, style: const TextStyle(fontSize: TextSize.title2, fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(w.unit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
                ),
              ]),
            const SizedBox(height: 8),
            Expanded(child: strip),
          ]),
        ),
      ),
    );
  }
}

/// Desktop Explore: a category as an album: a rounded square of its
/// photos (slowly changing), with the name and count underneath.
class _AlbumTile extends StatefulWidget {
  const _AlbumTile({
    super.key,
    required this.tag,
    required this.title,
    required this.icon,
    required this.count,
    required this.cover,
    required this.loadCovers,
    required this.index,
    required this.onTap,
  });

  final String tag, title, cover;
  final IconData icon;
  final int count, index;
  final Future<List<String>> Function() loadCovers;
  final ValueChanged<String> onTap;

  @override
  State<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<_AlbumTile> {
  late List<String> _covers = [widget.cover];
  int _i = 0;
  Timer? _timer;
  bool _hover = false;
  ValueListenable<TickerModeData>? _active;

  @override
  void initState() {
    super.initState();
    widget.loadCovers().then((all) {
      if (!mounted || all.length < 2) return;
      _covers = all.take(4).toList();
      _timer = Timer.periodic(Duration(milliseconds: 4500 + 600 * (widget.index % 5)), (_) {
        if (mounted && !_hover && (_active?.value.enabled ?? true)) setState(() => _i = (_i + 1) % _covers.length);
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.getValuesNotifier(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = _covers[_i];
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.onTap(id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: scheme.surfaceContainerHighest,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: _hover ? 0.2 : 0.06),
                    blurRadius: _hover ? 14 : 3,
                    offset: Offset(0, _hover ? 5 : 1),
                  ),
                ],
              ),
              child: Stack(fit: StackFit.expand, children: [
                Hero(
                  tag: 'cat-${widget.tag}',
                  child: AnimatedScale(
                    scale: _hover ? 1.05 : 1,
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 700),
                      child: KeyedSubtree(key: ValueKey(id), child: AssetThumb(id: id, size: 320)),
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(7)),
                    child: Icon(widget.icon, color: Colors.white, size: 15),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 7),
          Text(widget.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
          Text('${widget.count} ${widget.count == 1 ? 'photo' : 'photos'}',
              style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
