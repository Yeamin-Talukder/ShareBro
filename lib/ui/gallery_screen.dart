import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../data/db.dart';
import '../data/gallery.dart';
import '../data/trash.dart';
import '../scan/scan_controller.dart';
import 'face_refresh.dart';
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'scan_screen.dart';
import 'search_screen.dart';
import 'sections.dart';
import 'trash_screen.dart';
import 'widgets.dart';

/// Shown until the user allows photo access.
class _AccessGate extends StatefulWidget {
  const _AccessGate({required this.child});

  final Widget child;

  @override
  State<_AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<_AccessGate> {
  late Future<bool> _access = Gallery.requestAccess();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _access,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.data!) return widget.child;
        return EmptyIllustration(
          message: 'Allow photo access to browse your gallery.',
          action: FilledButton(
            onPressed: () async {
              await PhotoManager.openSetting();
              setState(() => _access = Gallery.requestAccess());
            },
            child: const Text('Allow access'),
          ),
        );
      },
    );
  }
}

/// Every photo and video on the phone, by day.
class PhotosTab extends StatefulWidget {
  const PhotosTab({super.key, required this.controller});

  final ScanController controller;

  @override
  State<PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<PhotosTab> {
  DaySpan? _dates;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        flexibleSpace: const Glass(
          radius: 0,
          shadow: false,
          child: SizedBox.expand(),
        ),
        title: const Text('Photos', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => SearchScreen(controller: widget.controller))),
          ),
          DateChip(value: _dates, onChanged: (d) => setState(() => _dates = d)),
          const SizedBox(width: 12),
        ],
      ),
      body: _AccessGate(
        child: GalleryView(
          key: ValueKey(_dates),
          controller: widget.controller,
          source: GallerySource.album(
            () => Gallery.allPhotos(dates: _dates, media: true),
          ),
          emptyMessage: _dates == null
              ? 'No photos on this phone yet.'
              : 'No photos taken in these dates.',
        ),
      ),
    );
  }
}

/// The phone's albums (Camera, WhatsApp Images, …).
class AlbumsTab extends StatefulWidget {
  const AlbumsTab({super.key, required this.controller});

  final ScanController controller;

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab> {
  DaySpan? _dates;
  late Future<List<AssetPathEntity>> _albums = Gallery.albums(media: true);

  void _setDates(DaySpan? d) => setState(() {
    _dates = d;
    _albums = Gallery.albums(dates: d, media: true);
  });

  void _openSmart(
    String title,
    Future<AssetPathEntity?> Function(DaySpan?) load,
    String empty,
  ) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => SmartAlbumScreen(
        controller: widget.controller,
        title: title,
        load: load,
        empty: empty,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // Large title that scrolls away, with the dates in the top bar.
    Widget page(List<Widget> slivers) => GlassScrollView(
          title: 'Albums',
          actions: [DateChip(value: _dates, onChanged: _setDates), const SizedBox(width: 12)],
          slivers: slivers,
        );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _AccessGate(
        child: FutureBuilder<List<AssetPathEntity>>(
          future: _albums,
          builder: (context, snap) {
            final albums = snap.data;
            if (albums == null) {
              return page(const [SliverFillRemaining(child: Center(child: CircularProgressIndicator()))]);
            }
            if (albums.isEmpty) {
              return page(const [
                SliverFillRemaining(hasScrollBody: false, child: EmptyIllustration(message: 'No albums found.')),
              ]);
            }
            return FaceRefresh(
              onRefresh: () async {
                _setDates(_dates);
                await _albums;
              },
              child: page([
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: _SmartCard(
                            icon: Icons.favorite_rounded,
                            title: 'Favourites',
                            color: const Color(0xFFE8457A),
                            onTap: () => _openSmart(
                              'Favourites',
                              (_) => Gallery.favourites(),
                              'Tap the heart on a photo to add it here.',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _SmartCard(
                            icon: Icons.movie_rounded,
                            title: 'Videos',
                            color: const Color(0xFF6E5BFF),
                            onTap: () => _openSmart(
                              'Videos',
                              (d) => Gallery.videos(dates: d ?? _dates),
                              'No videos here.',
                            ),
                          ),
                        ),
                        // The phone's trash (Android 11+ only).
                        FutureBuilder<bool>(
                          future: Trash.available(),
                          builder: (context, snap) => snap.data != true
                              ? const SizedBox.shrink()
                              : Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 10),
                                    child: _SmartCard(
                                      icon: Icons.delete_rounded,
                                      title: 'Trash',
                                      color: const Color(0xFF636366),
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => TrashScreen(controller: widget.controller),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ).animate().fadeIn().moveY(begin: 10),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(
                    child: SectionHeader(
                      title: 'My albums',
                      badge: Text('${albums.length}',
                          style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 16),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 200,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.8,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (context, i) => _AlbumCard(
                      album: albums[i],
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AlbumScreen(
                            controller: widget.controller,
                            album: albums[i],
                            dates: _dates,
                          ),
                        ),
                      ),
                    ).animate().fadeIn(delay: (40 * i.clamp(0, 12)).ms).scaleXY(begin: 0.92, curve: Curves.easeOutBack),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _AlbumCard extends StatefulWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final AssetPathEntity album;
  final VoidCallback onTap;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  AssetPathEntity get album => widget.album;
  late final Future<(AssetEntity?, int)> _cover = _load();

  Future<(AssetEntity?, int)> _load() async {
    final count = await album.assetCountAsync;
    final first = count == 0
        ? null
        : (await album.getAssetListRange(start: 0, end: 1)).firstOrNull;
    return (first, count);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Pressable(
      onTap: widget.onTap,
      child: FutureBuilder<(AssetEntity?, int)>(
        future: _cover,
        builder: (context, snap) {
          final (cover, count) = snap.data ?? (null, 0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: SizedBox.expand(
                    child: cover == null
                        ? ColoredBox(
                            color: scheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.photo_album_outlined,
                              size: 40,
                              color: scheme.outline,
                            ),
                          )
                        : AssetEntityImage(
                            cover,
                            isOriginal: false,
                            thumbnailSize: const ThumbnailSize.square(400),
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Text(
                album.isAll ? 'All photos' : album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall?.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              Text(snap.hasData ? '$count' : '…', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ],
          );
        },
      ),
    );
  }
}

class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.controller,
    required this.album,
    this.dates,
  });

  final ScanController controller;
  final AssetPathEntity album;
  final DaySpan? dates;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  late DaySpan? _dates = widget.dates;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.album.isAll ? 'All photos' : widget.album.name),
        actions: [
          DateChip(value: _dates, onChanged: (d) => setState(() => _dates = d)),
          IconButton(
            tooltip: 'Scan this album for faces',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: widget.controller.running
                ? null
                : () async {
                    // Faces come from photos only, so scan the photos-only view of the album.
                    final photos =
                        await Gallery.albumById(widget.album.id) ??
                        widget.album;
                    widget.controller.scan(photos, dates: _dates);
                    if (!context.mounted) return;
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ScanScreen(controller: widget.controller),
                      ),
                    );
                  },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: GalleryView(
        key: ValueKey(_dates),
        controller: widget.controller,
        source: GallerySource.album(
          () => Gallery.inRange(widget.album, _dates, media: true),
        ),
        emptyMessage: 'Nothing in this album for these dates.',
      ),
    );
  }
}

/// Favourites or Videos: a gallery over a filtered view of the library.
class SmartAlbumScreen extends StatefulWidget {
  const SmartAlbumScreen({
    super.key,
    required this.controller,
    required this.title,
    required this.load,
    required this.empty,
  });

  final ScanController controller;
  final String title;
  final Future<AssetPathEntity?> Function(DaySpan? dates) load;
  final String empty;

  @override
  State<SmartAlbumScreen> createState() => _SmartAlbumScreenState();
}

class _SmartAlbumScreenState extends State<SmartAlbumScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: GalleryView(
        controller: widget.controller,
        source: GallerySource.album(() => widget.load(null)),
        emptyMessage: widget.empty,
      ),
    );
  }
}

class _SmartCard extends StatelessWidget {
  const _SmartCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SectionCard(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 76,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(11)),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
