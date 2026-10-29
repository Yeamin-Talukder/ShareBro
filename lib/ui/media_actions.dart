import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/gallery.dart';
import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';
import 'send_to_sheet.dart';
import 'widgets.dart';

/// What a normal gallery can do with photos and videos: share, send to a
/// nearby device, favourite, put in an album and delete. Used by the grid's
/// selection bar and the full-screen viewer.
class MediaActions {
  MediaActions(this.context, this.controller);

  final BuildContext context;
  final ScanController controller;

  void _toast(String message, {IconData icon = Icons.check_rounded}) => Island.toast(message, icon: icon);

  static Future<List<AssetEntity>> resolve(Iterable<String> ids) async => [
        for (final id in ids) ?await AssetThumb.entity(id),
      ];

  /// Android's share sheet (WhatsApp, Quick Share, Drive, …).
  Future<void> share(List<AssetEntity> assets) async {
    final files = <XFile>[];
    for (final a in assets) {
      final f = await a.file;
      if (f != null) files.add(XFile(f.path, mimeType: a.mimeType));
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  /// Nearby devices (LocalSend, Nearby, web link).
  Future<void> send(List<AssetEntity> assets) => showSendToSheet(
        context,
        controller: controller,
        items: [for (final a in assets) SendItem.asset(a.id)],
      );

  /// Marks all as favourite, or un-marks them if they all already are.
  /// Returns the new state, or null if it couldn't be changed.
  Future<bool?> toggleFavourite(List<AssetEntity> assets) async {
    final fav = !assets.every((a) => a.isFavorite);
    try {
      for (final a in assets) {
        final updated = await PhotoManager.editor.android.favoriteAsset(entity: a, favorite: fav);
        AssetThumb.forget(a.id);
        AssetThumb.remember([updated]);
      }
      Haptics.tick();
      return fav;
    } catch (_) {
      _toast('Favourites need Android 11+', icon: Icons.info_outline_rounded);
      return null;
    }
  }

  /// Moves to the phone's trash (restorable for 30 days). Returns the ids
  /// that are gone.
  Future<Set<String>> trash(List<AssetEntity> assets) async {
    if (assets.isEmpty) return {};
    List<String> gone;
    try {
      gone = await PhotoManager.editor.android.moveToTrash(assets);
    } catch (_) {
      // Older Android has no trash: delete (the system asks first).
      gone = await PhotoManager.editor.deleteWithIds([for (final a in assets) a.id]);
    }
    for (final id in gone) {
      AssetThumb.forget(id);
    }
    await controller.db.forgetPhotos(gone);
    if (gone.isNotEmpty) {
      Haptics.success();
      final trashed = [for (final a in assets) if (gone.contains(a.id)) a];
      Island.toast(
        '${gone.length} to trash',
        icon: Icons.delete_outline_rounded,
        action: 'Undo',
        // Put them back (Android asks to confirm).
        onAction: () async {
          try {
            final back = await PhotoManager.editor.android.restoreFromTrash(trashed);
            if (back.isNotEmpty) Island.toast('${back.length} restored', icon: Icons.restore_rounded);
          } catch (_) {
            Island.toast('Restore from Albums › Trash', icon: Icons.info_outline_rounded);
          }
        },
      );
    }
    return gone.toSet();
  }

  /// Copy or move into an album (or a new one). Returns true when they
  /// were moved (and so may have left the album being viewed).
  Future<bool> addToAlbum(List<AssetEntity> assets) async {
    final pick = await showModalBottomSheet<_AlbumPick>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _AlbumPicker(count: assets.length),
    );
    if (pick == null) return false;
    var done = 0;
    try {
      if (pick.move) {
        final target = pick.album == null ? 'Pictures/${pick.newName}' : await _relativePath(pick.album!);
        if (target == null) {
          _toast('Can\'t move into this album', icon: Icons.info_outline_rounded);
          return false;
        }
        final ok = await PhotoManager.editor.android.moveAssetsToPath(entities: assets, targetPath: target);
        done = ok ? assets.length : 0;
        for (final a in assets) {
          AssetThumb.forget(a.id);
        }
      } else {
        for (final a in assets) {
          if (pick.album != null) {
            await PhotoManager.editor.copyAssetToPath(asset: a, pathEntity: pick.album!);
          } else {
            final file = await a.file;
            if (file == null) continue;
            final title = a.title ?? file.uri.pathSegments.last;
            if (a.type == AssetType.video) {
              await PhotoManager.editor.saveVideo(file, title: title, relativePath: 'Movies/${pick.newName}');
            } else {
              await PhotoManager.editor.saveImageWithPath(file.path,
                  title: title, relativePath: 'Pictures/${pick.newName}');
            }
          }
          done++;
        }
      }
    } catch (e) {
      _toast('Couldn\'t ${pick.move ? 'move' : 'copy'}', icon: Icons.error_outline_rounded);
      return false;
    }
    final name = pick.album?.name ?? pick.newName;
    if (done > 0) {
      Haptics.success();
      _toast('$done ${pick.move ? 'moved' : 'copied'} to $name', icon: Icons.photo_album_outlined);
    }
    return pick.move && done > 0;
  }

  /// The folder an album lives in ("DCIM/Camera"), from one of its items.
  static Future<String?> _relativePath(AssetPathEntity album) async {
    final first = (await album.getAssetListRange(start: 0, end: 1)).firstOrNull;
    final rel = first?.relativePath;
    if (rel == null || rel.isEmpty) return null;
    return rel.endsWith('/') ? rel.substring(0, rel.length - 1) : rel;
  }

  /// "Move 12 to trash?"
  Future<bool> confirmTrash(int count) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.delete_outline_rounded),
          title: Text('Move $count ${count == 1 ? 'item' : 'items'} to trash?'),
          content: const Text('You can restore them from the phone\'s trash for 30 days.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move to trash')),
          ],
        ),
      ) ??
      false;
}

class _AlbumPick {
  _AlbumPick({this.album, this.newName, required this.move});

  final AssetPathEntity? album;
  final String? newName;
  final bool move;
}

class _AlbumPicker extends StatefulWidget {
  const _AlbumPicker({required this.count});

  final int count;

  @override
  State<_AlbumPicker> createState() => _AlbumPickerState();
}

class _AlbumPickerState extends State<_AlbumPicker> {
  final _albums = Gallery.albums(media: true);
  bool _move = false;

  Future<void> _newAlbum() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New album'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Album name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Create')),
        ],
      ),
    );
    final clean = name?.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    if (clean == null || clean.isEmpty || !mounted) return;
    Navigator.pop(context, _AlbumPick(newName: clean, move: _move));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(children: [
            Expanded(child: Text('Add ${widget.count} to album', style: text.titleLarge)),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Copy')),
                ButtonSegment(value: true, label: Text('Move')),
              ],
              selected: {_move},
              onSelectionChanged: (s) => setState(() => _move = s.first),
            ),
          ]),
        ),
        Expanded(
          child: FutureBuilder<List<AssetPathEntity>>(
            future: _albums,
            builder: (context, snap) {
              final albums = [for (final a in snap.data ?? <AssetPathEntity>[]) if (!a.isAll) a];
              return ListView(controller: scroll, children: [
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
                  title: const Text('New album…'),
                  onTap: _newAlbum,
                ),
                if (!snap.hasData) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
                for (var i = 0; i < albums.length; i++)
                  ListTile(
                    leading: _AlbumThumb(album: albums[i]),
                    title: Text(albums[i].name),
                    onTap: () => Navigator.pop(context, _AlbumPick(album: albums[i], move: _move)),
                  ).animate().fadeIn(delay: (25 * i.clamp(0, 16)).ms).moveX(begin: 12),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

class _AlbumThumb extends StatelessWidget {
  const _AlbumThumb({required this.album});

  final AssetPathEntity album;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 44,
        child: FutureBuilder<List<AssetEntity>>(
          future: album.getAssetListRange(start: 0, end: 1),
          builder: (context, snap) {
            final a = snap.data?.firstOrNull;
            return a == null
                ? ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest)
                : AssetEntityImage(a, isOriginal: false, thumbnailSize: const ThumbnailSize.square(120), fit: BoxFit.cover);
          },
        ),
      ),
    );
  }
}

/// One action on the glass bar.
class ActionButton extends StatelessWidget {
  const ActionButton({super.key, required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: onTap == null ? fg.withValues(alpha: 0.4) : fg),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// The floating glass bar of actions, for a selection or the open photo.
class MediaActionBar extends StatelessWidget {
  const MediaActionBar({
    super.key,
    required this.onSend,
    required this.onShare,
    required this.onFavourite,
    required this.favourite,
    required this.onAlbum,
    required this.onTrash,
    this.kind = GlassKind.regular,
  });

  final VoidCallback? onSend, onShare, onFavourite, onAlbum, onTrash;
  final bool favourite;
  final GlassKind kind;

  @override
  Widget build(BuildContext context) {
    final clear = kind == GlassKind.clear;
    final fg = clear ? Colors.white : null;
    return Glass(
      kind: kind,
      radius: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(children: [
        ActionButton(icon: Icons.send_rounded, label: 'Send', onTap: onSend, color: Theme.of(context).colorScheme.primary),
        ActionButton(icon: Icons.share_outlined, label: 'Share', onTap: onShare, color: fg),
        ActionButton(
          icon: favourite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          label: favourite ? 'Unfavourite' : 'Favourite',
          onTap: onFavourite,
          color: favourite ? const Color(0xFFE8457A) : fg,
        ),
        ActionButton(icon: Icons.photo_album_outlined, label: 'Album', onTap: onAlbum, color: fg),
        ActionButton(icon: Icons.delete_outline_rounded, label: 'Delete', onTap: onTrash, color: fg),
      ]),
    );
  }
}
