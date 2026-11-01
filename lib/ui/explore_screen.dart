import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../face/tags.dart';
import '../scan/scan_controller.dart';
import '../data/duplicates.dart';
import '../data/group_shots.dart';
import 'best_shots_screen.dart';
import 'duplicates_screen.dart';
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'sections.dart';
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
    if (mounted) {
      setState(() {
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
        else ...[
          if (_dupes.isNotEmpty || _bursts.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: SectionCard.rows(rows: [
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
  final ScrollController scroll;
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
      width: _cardWidth,
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
      borderRadius: BorderRadius.circular(22),
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Material(
        color: dark ? const Color(0xC71C1C1F) : const Color(0xD9FFFFFF),
        child: InkWell(
          onTap: () => widget.onTap(_covers[_i]),
          onLongPress: _toggleFlip,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                ClipRect(
                  child: AnimatedBuilder(
                    // Parallax: the image drifts opposite to the row's scroll.
                    animation: widget.scroll,
                    builder: (context, child) {
                      final offset = widget.scroll.hasClients ? widget.scroll.offset : 0.0;
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
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Text('${widget.count} photos', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
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
                        color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
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
