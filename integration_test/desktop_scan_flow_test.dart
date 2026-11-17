// A real folder scan in the Windows app: batched saving, file reuse after a
// copy, and rescanning a changed file.
//
//   flutter test integration_test/desktop_scan_flow_test.dart -d windows
//     --dart-define=FLOW_PHOTOS=<empty work folder, filled by the test>
//     --dart-define=FLOW_SOURCE=<folder of JPEGs to copy in>
//
// Needs --dart-define=SB_DATA_DIR=<empty scratch folder> (never the real data).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/main.dart' as app;
import 'package:photo_organizer/ui/root_screen.dart';
import 'package:photo_organizer/platform/app_dirs.dart';

const _work = String.fromEnvironment('FLOW_PHOTOS');
const _source = String.fromEnvironment('FLOW_SOURCE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Never run against the real ShareBro data of whoever uses this PC.
  if (dataDirOverride.isEmpty) {
    throw StateError('Pass --dart-define=SB_DATA_DIR=<empty scratch folder>: this test runs the real app.');
  }

  testWidgets('desktop folder scan', (tester) async {
    Future<void> wait(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.runAsync(() => app.main());
    await wait(const Duration(seconds: 5));
    final c = tester.widget<RootScreen>(find.byType(RootScreen)).controller;

    Future<Duration> scan(String folder) async {
      final watch = Stopwatch()..start();
      final found = await tester.runAsync(() => c.scanDesktopFolder(folder));
      expect(found, greaterThan(0));
      await wait(const Duration(milliseconds: 500));
      final end = DateTime.now().add(const Duration(minutes: 5));
      while (c.running && DateTime.now().isBefore(end)) {
        await wait(const Duration(milliseconds: 200));
      }
      expect(c.running, isFalse, reason: 'scan finished');
      expect(c.error, isNull);
      return watch.elapsed;
    }

    // 1. A fresh folder of photos.
    final trip = Directory(p.join(_work, 'Trip'))..createSync(recursive: true);
    final sources = Directory(_source).listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final f in sources) {
      f.copySync(p.join(trip.path, p.basename(f.path)));
    }
    final first = await scan(trip.path);
    final ids = await tester.runAsync(() => c.db.photosIn()) ?? [];
    final people = await tester.runAsync(() => c.db.people()) ?? [];
    final faces = await tester.runAsync(() => c.db.faceCount()) ?? 0;
    expect(ids.length, sources.length, reason: 'every photo saved');
    expect(faces, greaterThan(0));

    // 2. The same photos copied into a second folder: their scans are
    // copied, not redone, so this is much quicker and adds the same faces.
    final copy = Directory(p.join(_work, 'Copy'))..createSync();
    for (final f in sources.take(6)) {
      f.copySync(p.join(copy.path, p.basename(f.path)));
    }
    final second = await scan(copy.path);
    final facesAfterCopy = await tester.runAsync(() => c.db.faceCount()) ?? 0;

    // 3. One photo changed (another photo saved over it): scanned again.
    final changed = File(p.join(trip.path, p.basename(sources.first.path)));
    sources.last.copySync(changed.path);
    final third = await scan(trip.path);
    final idsAfter = await tester.runAsync(() => c.db.photosIn()) ?? [];

    // ignore: avoid_print
    print('\nScan of ${sources.length} photos: ${first.inMilliseconds} ms '
        '(${(first.inMilliseconds / sources.length).round()} ms/photo), ${people.length} people, $faces faces\n'
        'Copied 6 photos: ${second.inMilliseconds} ms, faces $faces -> $facesAfterCopy\n'
        'Rescan with 1 changed photo: ${third.inMilliseconds} ms, photos ${idsAfter.length}\n'
        'Face engine: ${c.engineSummary}');
    expect(facesAfterCopy, greaterThan(faces), reason: 'copied photos keep their faces');
    expect(second.inMilliseconds, lessThan(first.inMilliseconds), reason: 'copies reuse their scans');
    expect(idsAfter.length, sources.length + 6);
  });
}
