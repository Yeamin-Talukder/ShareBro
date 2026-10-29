import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../data/db.dart';
import '../data/gallery.dart';
import 'motion.dart';
import 'widgets.dart';

/// What to scan: a phone album (optionally only some dates), or any folder.
class ScanChoice {
  ScanChoice.album(AssetPathEntity this.album, this.dates) : folder = null;
  ScanChoice.folder(String this.folder)
      : album = null,
        dates = null;

  final AssetPathEntity? album;
  final DaySpan? dates;
  final String? folder;
}

/// "What should I scan?" — any folder on the phone, or one of its albums,
/// optionally limited to certain dates.
Future<ScanChoice?> showScanSheet(BuildContext context) {
  return showModalBottomSheet<ScanChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      builder: (context, scroll) => _ScanSheet(scroll: scroll),
    ),
  );
}

class _ScanSheet extends StatefulWidget {
  const _ScanSheet({required this.scroll});

  final ScrollController scroll;

  @override
  State<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<_ScanSheet> {
  DaySpan? _dates;
  late Future<List<AssetPathEntity>> _albums = Gallery.albums();

  void _setDates(DaySpan? d) => setState(() {
        _dates = d;
        _albums = Gallery.albums(dates: d);
      });

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder to scan');
    if (path == null || !mounted) return;
    Haptics.success();
    Navigator.pop(context, ScanChoice.folder(path));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListView(controller: widget.scroll, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      Text('What should I scan?', style: text.headlineSmall),
      const SizedBox(height: 4),
      Text('Only photos the app hasn\'t seen yet are scanned; the rest are skipped.',
          style: text.bodySmall),
      const SizedBox(height: 16),
      Pressable(
        onTap: _pickFolder,
        child: Card(
          color: scheme.primaryContainer,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primary,
              child: Icon(Icons.create_new_folder_outlined, color: scheme.onPrimary),
            ),
            title: const Text('Choose a folder…', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Any folder on the phone or SD card, with its subfolders'),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ).animate().fadeIn().moveY(begin: 8),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: Text('Albums', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
        DateChip(value: _dates, onChanged: _setDates),
      ]),
      const SizedBox(height: 8),
      FutureBuilder<List<AssetPathEntity>>(
        future: _albums,
        builder: (context, snap) {
          final albums = snap.data;
          if (albums == null) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(children: [
            for (final (i, a) in albums.indexed)
              _AlbumRow(
                album: a,
                dated: _dates != null,
                onTap: () => Navigator.pop(context, ScanChoice.album(a, _dates)),
              ).animate().fadeIn(delay: (25 * i.clamp(0, 15)).ms).moveX(begin: 12),
          ]);
        },
      ),
    ]);
  }
}

/// An album with its cover photo and photo count.
class _AlbumRow extends StatefulWidget {
  const _AlbumRow({required this.album, required this.dated, required this.onTap});

  final AssetPathEntity album;
  final bool dated;
  final VoidCallback onTap;

  @override
  State<_AlbumRow> createState() => _AlbumRowState();
}

class _AlbumRowState extends State<_AlbumRow> {
  late final Future<(int, AssetEntity?)> _info = () async {
    final n = await widget.album.assetCountAsync;
    final first = n == 0 ? null : (await widget.album.getAssetListRange(start: 0, end: 1)).firstOrNull;
    return (n, first);
  }();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<(int, AssetEntity?)>(
      future: _info,
      builder: (context, snap) {
        final (n, cover) = snap.data ?? (-1, null);
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          enabled: n != 0,
          onTap: widget.onTap,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.square(
              dimension: 52,
              child: cover == null
                  ? ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(widget.album.isAll ? Icons.photo_library_outlined : Icons.folder_outlined,
                          color: scheme.outline),
                    )
                  : AssetEntityImage(cover,
                      isOriginal: false, thumbnailSize: const ThumbnailSize.square(150), fit: BoxFit.cover),
            ),
          ),
          title: Text(widget.album.isAll ? 'All photos' : widget.album.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(n < 0
              ? '…'
              : widget.dated
                  ? '$n photos in these dates'
                  : '$n photos'),
          trailing: const Icon(Icons.chevron_right),
        );
      },
    );
  }
}
