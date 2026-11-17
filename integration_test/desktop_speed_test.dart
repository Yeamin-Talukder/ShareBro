// Desktop scanning speed and GPU/CPU agreement, in the real Windows app:
//
//   flutter drive --profile -d windows --driver=test_driver/integration_test.dart
//     --target=integration_test/desktop_speed_test.dart
//     --dart-define=SPEED_PHOTOS=<folder of JPEGs>
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_organizer/face/accel.dart';
import 'package:photo_organizer/face/face_engine.dart';
import 'package:photo_organizer/scan/scan_item.dart';

const _photos = String.fromEnvironment('SPEED_PHOTOS');

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

  testWidgets('desktop scan speed', (tester) async {
    await tester.runAsync(() async {
      final files = Directory(_photos).listSync().whereType<File>().map((f) => f.path).toList()..sort();
      final out = StringBuffer('\nPhotos: ${files.length}\n');

      Future<(double, List<RgbaScan?>)> run(FaceEngine engine) async {
        // Warm-up: first runs load and plan the models.
        final warm = await DesktopScanItem(files.first).decodePixels();
        await engine.analyzeRgba(TransferableTypedData.fromList([warm!.$1]), warm.$2, warm.$3, minFace: 32);
        final results = List<RgbaScan?>.filled(files.length, null);
        var next = 0;
        final watch = Stopwatch()..start();
        Future<void> lane() async {
          while (next < files.length) {
            final i = next++;
            final item = DesktopScanItem(files[i]);
            final meta = item.readMeta();
            final px = await item.decodePixels();
            if (px == null) continue;
            results[i] = await engine.analyzeRgba(TransferableTypedData.fromList([px.$1]), px.$2, px.$3, minFace: 32);
            await meta;
          }
        }

        await Future.wait([for (var l = 0; l <= engine.parallel; l++) lane()]);
        return (watch.elapsedMilliseconds / files.length, results);
      }

      final auto = await FaceEngine.load(chip: AccelChoice.auto);
      final (autoMs, autoRes) = await run(auto);
      out.writeln('auto: ${auto.parallel} workers, GPU ${auto.onGpu}: ${autoMs.round()} ms/photo');
      auto.dispose();

      final cpu = await FaceEngine.load(chip: AccelChoice.cpu);
      final (cpuMs, cpuRes) = await run(cpu);
      out.writeln('cpu:  ${cpu.parallel} workers: ${cpuMs.round()} ms/photo');
      cpu.dispose();

      // Same faces and fingerprints either way.
      var faces = 0, worst = 1.0, countDiffs = 0;
      for (var i = 0; i < files.length; i++) {
        final a = autoRes[i]?.faces ?? const [], b = cpuRes[i]?.faces ?? const [];
        if (a.length != b.length) {
          countDiffs++;
          continue;
        }
        for (var k = 0; k < a.length; k++) {
          worst = math.min(worst, _cosine(a[k].embedding, b[k].embedding));
          faces++;
        }
      }
      out.writeln('agreement: $faces faces compared, lowest similarity ${worst.toStringAsFixed(4)}, '
          '$countDiffs photos with a different face count');
      // ignore: avoid_print
      print(out);
      expect(faces, greaterThan(0));
      expect(worst, greaterThan(0.98));
    });
  });
}
