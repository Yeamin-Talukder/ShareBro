import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/duplicates.dart';
import '../scan/scan_controller.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'widgets.dart';

/// Bursts and repeated poses, with the best shot of each picked. Extras can
/// be hidden inside the app (nothing changes on the phone) or moved to the
/// phone's trash, which Android asks you to confirm and keeps for 30 days.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  ScanController get c => widget.controller;
  List<DuplicateSet>? _sets;

  /// The user's own pick of the keeper, per set (index -> asset id).
  final Map<int, String> _keep = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sets = findDuplicates(await c.db.fingerprints());
    if (mounted) {
      setState(() {
        _sets = sets;
        _keep.clear();
      });
    }
  }

  String _keeper(int i) => _keep[i] ?? _sets![i].best;

  List<String> _extras(int i) => [
        for (final p in _sets![i].photos)
          if (p.assetId != _keeper(i)) p.assetId,
      ];

  Future<void> _hide(List<int> indexes) async {
    final ids = [for (final i in indexes) ..._extras(i)];
    final keepers = [for (final i in indexes) _keeper(i)];
    await c.db.setHidden(ids, true);
    await c.db.setHidden(keepers, false);
    Haptics.success();
    c.changed();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Hid ${ids.length} extra photos in the app'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await c.db.setHidden(ids, false);
            c.changed();
            await _load();
          },
        ),
      ));
  }

  Future<void> _unhide(int i) async {
    await c.db.setHidden(_sets![i].photos.map((p) => p.assetId), false);
    c.changed();
    await _load();
  }

  Future<void> _trash(int i) async {
    final ids = _extras(i);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Move ${ids.length} photos to the phone\'s trash?'),
        content: const Text(
            'Android will ask you to confirm. They stay in the trash for 30 days, '
            'so you can still restore them from your gallery app.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (ok != true) return;
    final assets = [
      for (final id in ids) ?(await AssetThumb.entity(id)),
    ];
    try {
      final moved = await PhotoManager.editor.android.moveToTrash(assets);
      await c.db.forgetPhotos(moved);
      Haptics.remove();
      c.changed();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This phone can\'t move photos to the trash. Hide them instead.')));
    }
  }

  void _open(DuplicateSet set, String id) {
    final ids = [for (final p in set.photos) p.assetId];
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(ids: ids, initial: ids.indexOf(id), controller: c),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sets = _sets;
    final text = Theme.of(context).textTheme;
    final open = sets == null
        ? const <int>[]
        : [for (var i = 0; i < sets.length; i++) if (!sets[i].allExtrasHidden) i];
    final extraCount = open.fold<int>(0, (n, i) => n + sets![i].photos.length - 1);
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicates')),
      body: sets == null
          ? const PhotosSkeleton(columns: 4)
          : sets.isEmpty
              ? const EmptyIllustration(
                  message: 'No near-duplicate photos found.\n'
                      'Scan an album and bursts or repeated poses show up here.')
              : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${open.length} sets · $extraCount extra photos',
                            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text('The ⭐ shot is the sharpest with eyes open and smiles. '
                            'Tap another photo to keep that one instead; long-press to view.',
                            style: text.bodySmall),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: open.isEmpty ? null : () => _hide(open),
                          icon: const Icon(Icons.visibility_off_outlined),
                          label: const Text('Hide all extras in the app'),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < sets.length; i++)
                    _SetCard(
                      set: sets[i],
                      keeper: _keeper(i),
                      onPick: (id) {
                        Haptics.tick();
                        setState(() => _keep[i] = id);
                      },
                      onOpen: (id) => _open(sets[i], id),
                      onHide: () => _hide([i]),
                      onUnhide: () => _unhide(i),
                      onTrash: () => _trash(i),
                    ).animate().fadeIn(delay: (30 * i.clamp(0, 10)).ms).moveY(begin: 12),
                ]),
    );
  }
}

class _SetCard extends StatelessWidget {
  const _SetCard({
    required this.set,
    required this.keeper,
    required this.onPick,
    required this.onOpen,
    required this.onHide,
    required this.onUnhide,
    required this.onTrash,
  });

  final DuplicateSet set;
  final String keeper;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onOpen;
  final VoidCallback onHide, onUnhide, onTrash;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = set.allExtrasHidden;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: 118,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(10),
              children: [
                for (final p in set.photos)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => onPick(p.assetId),
                      onLongPress: () => onOpen(p.assetId),
                      child: AnimatedContainer(
                        duration: 200.ms,
                        width: 98,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: p.assetId == keeper ? scheme.primary : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: Stack(fit: StackFit.expand, children: [
                            Opacity(
                              opacity: p.assetId != keeper && hidden ? 0.35 : 1,
                              child: AssetThumb(id: p.assetId, size: 200),
                            ),
                            if (p.assetId == keeper)
                              Positioned(
                                top: 4,
                                left: 4,
                                child: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: scheme.primary,
                                  child: Icon(Icons.star_rounded, size: 16, color: scheme.onPrimary),
                                ).animate(key: ValueKey(keeper)).scaleXY(
                                    begin: 0, curve: Curves.elasticOut, duration: 500.ms),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
            child: Row(children: [
              Text('${set.photos.length} similar',
                  style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              if (hidden)
                TextButton.icon(
                  onPressed: onUnhide,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Show again'),
                )
              else ...[
                TextButton(onPressed: onTrash, child: const Text('Move to trash')),
                FilledButton.tonal(onPressed: onHide, child: const Text('Hide extras')),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}
