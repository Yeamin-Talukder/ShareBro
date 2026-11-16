import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'anim.dart';

import '../data/db.dart';
import '../platform/desktop_library.dart';
import '../scan/desktop_folders.dart';
import '../scan/scan_controller.dart';
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'scan_screen.dart';
import 'sections.dart';
import 'theme.dart';
import 'widgets.dart';

/// Desktop's Albums tab: the folders scanned so far, each opening its
/// photos. "Add folder" scans another one.
class DesktopAlbumsTab extends StatefulWidget {
  const DesktopAlbumsTab({super.key, required this.controller});

  final ScanController controller;

  @override
  State<DesktopAlbumsTab> createState() => _DesktopAlbumsTabState();
}

class _DesktopAlbumsTabState extends State<DesktopAlbumsTab> {
  ScanController get c => widget.controller;
  late Future<List<_Folder>> _folders = _load();
  bool _wasRunning = false;

  /// Album cards that have already played their entrance.
  final _shown = <int>{};

  @override
  void initState() {
    super.initState();
    c.addListener(_onScan);
  }

  @override
  void dispose() {
    c.removeListener(_onScan);
    super.dispose();
  }

  /// A scan just finished: its folder (and photo count) may be new.
  void _onScan() {
    if (_wasRunning && !c.running && mounted) setState(() => _folders = _load());
    _wasRunning = c.running;
  }

  Future<List<_Folder>> _load() async {
    final out = <_Folder>[];
    for (final t in await c.db.trips()) {
      final folder = desktopFolderOf(t.albumId);
      if (folder == null) continue;
      final ids = await c.db.photosIn(tripId: t.id);
      out.add(_Folder(t, folder, ids.firstOrNull, ids.length));
    }
    return out;
  }

  Future<void> _addFolder() => addDesktopFolder(context, c);

  @override
  Widget build(BuildContext context) {
    Widget page(List<Widget> slivers) => GlassScrollView(
          title: 'Albums',
          actions: [
            ToolbarCapsule(children: [
              IconButton(
                tooltip: 'Add a folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: _addFolder,
              ),
            ]),
            const SizedBox(width: 12),
          ],
          slivers: slivers,
        );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FutureBuilder<List<_Folder>>(
        future: _folders,
        builder: (context, snap) {
          final folders = snap.data;
          if (folders == null) {
            return page(const [SliverFillRemaining(child: Center(child: CircularProgressIndicator()))]);
          }
          if (folders.isEmpty) {
            return page([
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyIllustration(
                  message: 'Folders you scan show up here.\nEverything stays on this computer.',
                  action: FilledButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Scan a folder'),
                  ),
                ),
              ),
            ]);
          }
          return page([
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverToBoxAdapter(
                child: SectionHeader(
                  title: 'Scanned folders',
                  badge: Text('${folders.length}',
                      style: TextStyle(fontSize: TextSize.callout, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.paddingOf(context).bottom + 16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.8,
                ),
                itemCount: folders.length,
                itemBuilder: (context, i) {
                  final f = folders[i];
                  final card = _FolderCard(
                    folder: f,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => DesktopFolderPage(
                              controller: c, tripId: f.trip.id, name: f.trip.name, path: f.path, embedded: false)),
                    ),
                  );
                  // Once each: cards scrolling back into view don't pop in again.
                  return _shown.add(i)
                      ? card.animate().fadeIn(delay: (40 * i.clamp(0, 12)).ms).scaleXY(begin: 0.92, curve: Curves.easeOutBack)
                      : card;
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _Folder {
  _Folder(this.trip, this.path, this.cover, this.count);

  final TripSummary trip;
  final String path;
  final String? cover;
  final int count;
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({required this.folder, required this.onTap});

  final _Folder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      child: Tooltip(
        message: folder.path,
        waitDuration: const Duration(milliseconds: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox.expand(
                  child: folder.cover == null
                      ? ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(Icons.folder_outlined, size: 40, color: scheme.outline),
                        )
                      : AssetThumb(id: folder.cover!, size: 400),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Text(
              folder.trip.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall?.copyWith(fontSize: TextSize.callout, fontWeight: FontWeight.w700),
            ),
            Text('${folder.count}', style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Desktop: picks a folder of photos and scans it (and the folders inside
/// it), then shows the scan. Says so when there's nothing to scan.
Future<void> addDesktopFolder(BuildContext context, ScanController c) async {
  final folder = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder of photos to scan');
  if (folder == null || !context.mounted) return;
  final found = await c.scanDesktopFolder(folder);
  if (!context.mounted) return;
  if (found == 0) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(c.running
            ? 'A scan is already running. Try again when it finishes.'
            : 'No photos in that folder (JPEG, PNG, WebP, GIF or BMP).')));
    return;
  }
  Navigator.push(context, MaterialPageRoute(builder: (_) => ScanScreen(controller: c)));
}

/// One scanned folder's photos, newest first, with a large title and the
/// folder's actions (show it in File Explorer, scan it for new photos, a
/// date filter). Works inside the desktop sidebar's content area, or as its
/// own screen ([embedded] false adds a back button).
class DesktopFolderPage extends StatefulWidget {
  const DesktopFolderPage({
    super.key,
    required this.controller,
    required this.tripId,
    required this.name,
    required this.path,
    this.embedded = true,
  });

  final ScanController controller;
  final int tripId;
  final String name;

  /// The folder on disk.
  final String path;
  final bool embedded;

  @override
  State<DesktopFolderPage> createState() => _DesktopFolderPageState();
}

class _DesktopFolderPageState extends State<DesktopFolderPage> {
  DaySpan? _dates;

  ScanController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        backgroundColor: widget.embedded ? Colors.transparent : null,
        appBar: AppBar(
          toolbarHeight: 76,
          titleSpacing: widget.embedded ? 24 : 4,
          automaticallyImplyLeading: !widget.embedded,
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: TextSize.title1, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            Text(widget.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: TextSize.small,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                    color: scheme.onSurface.withValues(alpha: 0.5))),
          ]),
          actions: [
            DateChip(value: _dates, onChanged: (d) => setState(() => _dates = d)),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Show in File Explorer',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: () => revealInFolder(widget.path),
            ),
            IconButton(
              tooltip: c.running ? 'A scan is running' : 'Scan for new photos',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: c.running
                  ? null
                  : () async {
                      await c.scanDesktopFolder(widget.path);
                      if (!context.mounted) return;
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ScanScreen(controller: c)));
                    },
            ),
            const SizedBox(width: 20),
          ],
        ),
        body: GalleryView(
          // Reloads when a scan starts and when it finishes.
          key: ValueKey((_dates, c.running)),
          controller: c,
          source: GallerySource.ids(() => c.db.photosIn(tripId: widget.tripId, dates: _dates)),
          emptyMessage: _dates == null ? 'No photos in this folder.' : 'No photos taken in these dates.',
        ),
      ),
    );
  }
}
