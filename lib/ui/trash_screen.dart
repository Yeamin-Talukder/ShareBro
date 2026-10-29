import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/trash.dart';
import '../scan/scan_controller.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';
import 'widgets.dart';

/// Recently deleted: everything in the phone's trash, with how long it has
/// left. Tap to select, then restore or delete forever.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashItem>? _items;
  String? _error;
  final Set<int> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await Trash.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
        _selected.retainWhere((id) => items.any((i) => i.id == id));
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t open the trash ($e)');
    }
  }

  List<TrashItem> get _chosen => [for (final i in _items ?? const <TrashItem>[]) if (_selected.contains(i.id)) i];

  void _toggle(TrashItem i) {
    Haptics.tick();
    setState(() => _selected.contains(i.id) ? _selected.remove(i.id) : _selected.add(i.id));
  }

  void _toast(String text, {IconData icon = Icons.check_rounded}) => Island.toast(text, icon: icon);

  Future<void> _restore(List<TrashItem> items) async {
    if (items.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final n = await Trash.restore(items);
      if (n > 0) {
        Haptics.success();
        // Back in the gallery; the library watcher re-scans their faces.
        _toast('$n restored', icon: Icons.restore_rounded);
      }
    } catch (e) {
      _toast('Couldn\'t restore', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _delete(List<TrashItem> items, {bool everything = false}) async {
    if (items.isEmpty || _busy) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_forever_rounded),
        title: Text(everything
            ? 'Empty the trash?'
            : 'Delete ${items.length} ${items.length == 1 ? 'item' : 'items'} forever?'),
        content: const Text('They\'ll be gone from this phone for good. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busy = true);
    try {
      final n = await Trash.deleteForever(items);
      if (n > 0) _toast('$n deleted forever', icon: Icons.delete_forever_rounded);
    } catch (e) {
      _toast('Couldn\'t delete', icon: Icons.error_outline_rounded);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final text = Theme.of(context).textTheme;
    final selecting = _selected.isNotEmpty;
    final total = items?.fold<int>(0, (n, i) => n + i.size) ?? 0;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(selecting ? '${_selected.length} selected' : 'Trash'),
          leading: selecting
              ? IconButton(
                  tooltip: 'Done', onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close_rounded))
              : null,
          actions: [
            if (items != null && items.isNotEmpty)
              TextButton(
                onPressed: () => setState(() =>
                    _selected.length == items.length ? _selected.clear() : _selected.addAll(items.map((i) => i.id))),
                child: Text(_selected.length == items.length ? 'Select none' : 'Select all'),
              ),
            if (items != null && items.isNotEmpty && !selecting)
              PopupMenuButton<String>(
                onSelected: (v) => v == 'empty' ? _delete(items, everything: true) : _restore(items),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'restore', child: Text('Restore all')),
                  PopupMenuItem(value: 'empty', child: Text('Empty trash')),
                ],
              ),
          ],
        ),
        body: switch ((items, _error)) {
          (_, final String e) => EmptyIllustration(message: e),
          (null, _) => const Center(child: CircularProgressIndicator()),
          (final List<TrashItem> list, _) when list.isEmpty => const EmptyIllustration(
              message: 'The trash is empty.\nDeleted photos and videos stay here for 30 days.'),
          (final List<TrashItem> list, _) => RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded, size: 18, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${list.length} ${list.length == 1 ? 'item' : 'items'} · ${formatBytes(total)}. '
                          'Each is deleted for good when its time runs out.',
                          style: text.bodySmall,
                        ),
                      ),
                    ]),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(2, 0, 2, MediaQuery.paddingOf(context).bottom + 110),
                  sliver: SliverGrid.builder(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 130,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => _TrashTile(
                      item: list[i],
                      selected: _selected.contains(list[i].id),
                      selecting: selecting,
                      onTap: () => _toggle(list[i]),
                    ).animate().fadeIn(delay: (15 * i.clamp(0, 30)).ms, duration: 220.ms),
                  ),
                ),
              ]),
            ),
        },
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: AnimatedSwitcher(
          duration: 220.ms,
          transitionBuilder: (c, a) =>
              SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(a), child: c),
          child: !selecting
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Glass(
                    radius: 28,
                    padding: const EdgeInsets.all(8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _restore(_chosen),
                        icon: const Icon(Icons.restore_rounded),
                        label: Text('Restore ${_selected.length}'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                        onPressed: _busy ? null : () => _delete(_chosen),
                        icon: const Icon(Icons.delete_forever_rounded),
                        label: const Text('Delete'),
                      ),
                    ]),
                  ),
                ),
        ),
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({required this.item, required this.selected, required this.selecting, required this.onTap});

  final TrashItem item;
  final bool selected, selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final days = item.daysLeft;
    const shadow = [Shadow(color: Colors.black54, blurRadius: 4)];
    return GestureDetector(
      onTap: onTap,
      child: ColoredBox(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        child: Stack(fit: StackFit.expand, children: [
          AnimatedScale(
            scale: selected ? 0.84 : 1,
            duration: 180.ms,
            curve: Curves.easeOutCubic,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(selected ? 12 : 2),
              child: FutureBuilder<Uint8List?>(
                future: Trash.thumbnail(item),
                builder: (context, snap) {
                  final bytes = snap.data;
                  if (bytes == null) {
                    return ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: snap.connectionState == ConnectionState.done
                          ? Icon(item.isVideo ? Icons.movie_outlined : Icons.image_outlined, color: scheme.outline)
                          : null,
                    );
                  }
                  // Dimmed a little: these are on their way out.
                  return Opacity(
                    opacity: 0.85,
                    child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                        .animate()
                        .fadeIn(duration: 160.ms),
                  );
                },
              ),
            ),
          ),
          Positioned(
            left: 4,
            right: 4,
            bottom: 4,
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: days <= 3 ? scheme.error.withValues(alpha: 0.85) : Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(days <= 0 ? 'today' : '$days d',
                    style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
              ),
              const Spacer(),
              if (item.isVideo) const Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white, shadows: shadow),
            ]),
          ),
          if (selecting)
            Positioned(
              top: 6,
              left: 6,
              child: AnimatedContainer(
                duration: 160.ms,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.black26,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: selected ? Icon(Icons.check_rounded, size: 14, color: scheme.onPrimary) : null,
              ),
            ),
        ]),
      ),
    );
  }
}
