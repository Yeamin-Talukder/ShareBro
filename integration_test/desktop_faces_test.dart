// Runs inside the real desktop app, with ONNX Runtime and the bundled face
// models:  flutter test integration_test/desktop_faces_test.dart -d windows
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/face/face_engine.dart';
import 'package:photo_organizer/scan/desktop_folders.dart';
import 'package:photo_organizer/scan/scan_item.dart';

/// Stock photos from the reel's demo trip (no real friends' faces).
const _trip = 'design/sharebro-reel/src/img/trip';

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / math.sqrt(na * nb);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('finds and fingerprints faces on desktop', (tester) async {
    await tester.runAsync(() async {
      final engine = await FaceEngine.load();
      final photo = p.join(_trip, 'pn_7624931.jpg');

      final watch = Stopwatch()..start();
      final faces = await engine.analyze(photo);
      final firstMs = watch.elapsedMilliseconds;
      // InsightFace finds five faces in this 900x600 photo; like on the
      // phone, the ones under 40 px or turned side-on are skipped, which
      // leaves one (43 px wide, facing the camera).
      expect(faces.length, 1);
      for (final f in faces) {
        expect(f.embedding.length, 512);
        expect(f.width, greaterThan(0));
        expect(f.thumb, isNotEmpty);
      }

      // The same photo again gives the same fingerprints.
      final again = await engine.analyze(photo);
      expect(again.length, faces.length);
      expect(_cosine(faces.first.embedding, again.first.embedding), greaterThan(0.99));

      // A scan of the whole demo folder, the way the app does it.
      final files = await listPhotoFiles(_trip);
      expect(files, isNotEmpty);
      watch.reset();
      var found = 0, scanned = 0;
      final tmp = File(p.join(Directory.systemTemp.path, 'sharebro_it_scan.jpg'));
      for (final path in files.take(12)) {
        final item = DesktopScanItem(path);
        final jpeg = await item.scanJpeg(1600);
        if (jpeg == null) continue;
        await tmp.writeAsBytes(jpeg);
        found += (await engine.analyze(tmp.path)).length;
        expect(await item.hash(), isNotNull);
        scanned++;
      }
      final perPhoto = watch.elapsedMilliseconds / math.max(1, scanned);
      // ignore: avoid_print
      print('First photo: ${faces.length} faces in $firstMs ms (includes model warm-up). '
          'Folder: $scanned photos, $found faces, ${perPhoto.round()} ms per photo.');
      expect(scanned, greaterThan(0));
      expect(found, greaterThan(0));
      engine.dispose();
    });
  });
}
