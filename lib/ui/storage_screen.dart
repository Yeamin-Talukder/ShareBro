import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/duplicates.dart';
import '../scan/scan_controller.dart';
import 'photo_viewer.dart';
import 'widgets.dart';

/// How much space scanned photos take: per trip, the biggest photos, and
/// how much duplicates and screenshots use.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  ScanController get c => widget.controller;
  int _measured = 0, _toMeasure = 0;
  _Report? _report;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final sizes = await c.db.photoSizes();
    final missing = [for (final e in sizes.entries) if (e.value == null) e.key];
    setState(() => _toMeasure = missing.length);
    // File sizes aren't in the photo library listing, so read each once and
    // remember it.
    final found = <String, int>{};
    for (final id in missing) {
      try {
        final file = await (await AssetThumb.entity(id))?.file;
        if (file != null) found[id] = await file.length();
      } catch (_) {}
      _measured++;
      if (_measured % 50 == 0) {
        await c.db.setSizes(found);
        found.clear();
        if (mounted) setState(() {});
      }
    }
    await c.db.setSizes(found);

    final all = await c.db.photoSizes();
    int sum(Iterable<String> ids) => ids.fold(0, (n, id) => n + (all[id] ?? 0));
    final trips = <(String, int)>[];
    for (final t in await c.db.trips()) {
      final s = await c.db.photoSizes(tripId: t.id);
      trips.add((t.name, s.values.fold<int>(0, (n, b) => n + (b ?? 0))));
    }
    trips.sort((a, b) => b.$2.compareTo(a.$2));
    final dupes = findDuplicates(await c.db.fingerprints());
    final largest = (all.entries.where((e) => e.value != null).toList()
          ..sort((a, b) => b.value!.compareTo(a.value!)))
        .take(12)
        .map((e) => (e.key, e.value!))
        .toList();
    final report = _Report(
      total: sum(all.keys),
      photos: all.length,
      trips: trips,
      duplicates: sum(dupes.expand((d) => d.extras)),
      screenshots: sum(await c.db.photosWithTag('screenshot')),
      largest: largest,
    );
    if (mounted) setState(() => _report = report);
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: r == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_toMeasure == 0
                    ? 'Adding up…'
                    : 'Measuring photos $_measured of $_toMeasure'),
              ]),
            )
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(formatBytes(r.total),
                        style: text.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
                    Text('in ${r.photos} scanned photos', style: text.bodyMedium),
                    const SizedBox(height: 16),
                    _Bar('Duplicates you could clear', r.duplicates, r.total,
                        Theme.of(context).colorScheme.tertiary),
                    _Bar('Screenshots', r.screenshots, r.total,
                        Theme.of(context).colorScheme.secondary),
                  ]),
                ),
              ).animate().fadeIn().moveY(begin: 10),
              if (r.trips.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('By trip', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                for (final (name, bytes) in r.trips)
                  _Bar(name, bytes, r.trips.first.$2, Theme.of(context).colorScheme.primary),
              ],
              if (r.largest.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Largest photos',
                    style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: r.largest.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final (id, bytes) = r.largest[i];
                      return GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          PageRouteBuilder(
                            opaque: false,
                            pageBuilder: (_, a, _) => FadeTransition(
                              opacity: a,
                              child: PhotoViewer(
                                ids: [for (final l in r.largest) l.$1],
                                initial: i,
                                controller: c,
                              ),
                            ),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox(
                            width: 100,
                            child: Stack(fit: StackFit.expand, children: [
                              Hero(tag: 'photo-$id', child: AssetThumb(id: id, size: 200)),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: double.infinity,
                                  color: Colors.black54,
                                  padding: const EdgeInsets.all(4),
                                  child: Text(formatBytes(bytes),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ]),
    );
  }
}

class _Report {
  _Report({
    required this.total,
    required this.photos,
    required this.trips,
    required this.duplicates,
    required this.screenshots,
    required this.largest,
  });

  final int total, photos, duplicates, screenshots;
  final List<(String, int)> trips;
  final List<(String, int)> largest;
}

/// A labelled bar that grows to its share of [max].
class _Bar extends StatelessWidget {
  const _Bar(this.label, this.value, this.max, this.color);

  final String label;
  final int value, max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(formatBytes(value), style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: max == 0 ? 0 : value / max),
          duration: 900.ms,
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: v, minHeight: 10, color: color),
          ),
        ),
      ]),
    );
  }
}
