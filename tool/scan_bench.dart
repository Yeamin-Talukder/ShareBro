// Measures the desktop scan, stage by stage, on real photos.
//
//   flutter run -d windows --release -t tool/scan_bench.dart
//     --dart-define=SB_SCAN_TIMING=true
//     --dart-define=SB_BENCH_DIR=C:\path\to\photos
//     --dart-define=SB_BENCH_OUT=C:\path\to\report.txt
//
// It decodes photos the way a scan does (DesktopScanItem.decodePixels),
// sends them to the real face engine (FaceEngine.analyzeRgba), and reports
// where the time goes, then tries a few settings (photos decoding ahead,
// decode size, no preview) to see what would make scans faster. Nothing is
// saved to the app's database. Close the window to stop it early.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart' show OrtEnv;
import 'package:photo_organizer/face/ort_lite.dart';
import 'package:image/image.dart' as img;
import 'package:photo_organizer/face/tags.dart' show differenceHash;
import 'package:photo_organizer/face/face_engine.dart';
import 'package:photo_organizer/scan/desktop_folders.dart';
import 'package:photo_organizer/scan/scan_item.dart';

const _dir = String.fromEnvironment('SB_BENCH_DIR');
const _out = String.fromEnvironment('SB_BENCH_OUT');

/// Photos per run (the list repeats when there are fewer).
const _photos = int.fromEnvironment('SB_BENCH_PHOTOS', defaultValue: 90);

final _log = StringBuffer();
final _status = ValueNotifier<String>('Starting…');

void say(String line) {
  _log.writeln(line);
  // ignore: avoid_print
  print(line);
  _status.value = _log.toString();
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<String>(
          valueListenable: _status,
          builder: (_, s, _) => SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.all(16),
            child: SelectableText(s, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
          ),
        ),
      ),
    ),
  );
  unawaited(_run().catchError((Object e, StackTrace st) => say('FAILED: $e\n$st')).whenComplete(_finish));
}

Future<void> _finish() async {
  if (_out.isNotEmpty) await File(_out).writeAsString(_log.toString());
  say('\nDone. Report: ${_out.isEmpty ? '(not saved)' : _out}');
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}

Future<void> _run() async {
  if (!scanTiming) say('Note: built without SB_SCAN_TIMING=true, so no per-stage worker times.');
  final folders = _dir.isEmpty ? ['${Platform.environment['USERPROFILE']}\\Pictures'] : _dir.split(';');
  final all = <String>[];
  for (final f in folders) {
    all.addAll(await listPhotoFiles(f));
  }
  // Camera-sized photos only: tiny images would flatter the numbers.
  final paths = [
    for (final p in all)
      if (p.toLowerCase().endsWith('.jpg') || p.toLowerCase().endsWith('.jpeg'))
        if (File(p).lengthSync() > 1000000) p,
  ];
  if (paths.isEmpty) throw 'No JPEGs over 1 MB in $folders';
  say('ShareBro scan benchmark · ${DateTime.now()}');
  say(
    '${Platform.numberOfProcessors} logical processors · ${paths.length} distinct photos '
    '(cycled to $_photos per run; repeat reads come from the file cache)',
  );

  // Fingerprint model setups, each in a fresh engine. The first is what
  // scans use today; it runs again at the end to show drift.
  say('\n== Fingerprint model alone (nothing else running) ==');
  final model = await rootBundle.load('assets/models/desktop/w600k_mbf.onnx');
  final bytes = model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes);
  for (final (gpu, threads, batch) in [
    (false, 1, 1),
    (false, 2, 1),
    (false, 4, 1),
    (false, 1, 4),
    (false, 2, 4),
    (false, 4, 4),
    (true, 1, 1),
  ]) {
    final line = await Isolate.run(() => _modelAlone(bytes, gpu: gpu, threads: threads, batch: batch));
    say('  $line');
  }

  // Each setup twice, interleaved, so drift and noise show up.
  final setups = <(String, FingerprintConfig?)>[
    ('OLD 1. fingerprints on the CPU', const FingerprintConfig()),
    ("NEW 1. the app's setup (fingerprints on the graphics chip)", null),
    ('OLD 2. fingerprints on the CPU', const FingerprintConfig()),
    ("NEW 2. the app's setup", null),
  ];
  Map<String, List<Float32List>>? baseline;
  for (final (name, config) in setups) {
    debugFingerprintConfig = config;
    final sw = Stopwatch()..start();
    final engine = await FaceEngine.load();
    say('\n== $name ==');
    try {
      say(
        '  engine: ${engine.parallel} workers${engine.onGpu ? ', detector on the graphics chip' : ''} · '
        'fingerprints: ${config ?? 'app default'} · loaded in ${sw.elapsedMilliseconds} ms',
      );
      // Warm up: first runs compile shaders and allocate.
      await _pipeline(engine, paths, photos: engine.parallel * 2, lanes: engine.parallel + 1, quiet: true);
      final prints = <String, List<Float32List>>{};
      await _pipeline(engine, paths, photos: _photos, lanes: engine.parallel + 1, prints: prints);
      if (baseline == null) {
        baseline = prints;
      } else {
        _comparePrints(baseline, prints);
      }
    } catch (e) {
      say('  FAILED: $e');
    }
    engine.dispose();
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  debugFingerprintConfig = null;
}

/// How close each setup's fingerprints are to today's, face by face. Two
/// photos of the same person score about 0.5; the app trusts a chip at 0.99.
void _comparePrints(Map<String, List<Float32List>> a, Map<String, List<Float32List>> b) {
  final sims = <double>[];
  var mismatched = 0;
  a.forEach((path, fa) {
    final fb = b[path];
    if (fb == null || fb.length != fa.length) {
      mismatched++;
      return;
    }
    for (var i = 0; i < fa.length; i++) {
      var dot = 0.0;
      for (var k = 0; k < fa[i].length; k++) {
        dot += fa[i][k] * fb[i][k];
      }
      sims.add(dot);
    }
  });
  if (sims.isEmpty) return say('  fingerprints vs today: nothing to compare');
  sims.sort();
  say(
    '  fingerprints vs today: ${sims.length} faces · lowest similarity ${sims.first.toStringAsFixed(4)} · '
    'median ${sims[sims.length ~/ 2].toStringAsFixed(4)}${mismatched > 0 ? ' · $mismatched photos with different face counts' : ''}',
  );
}

/// Decode timings: [inFlight] photos at once.
// ignore: unused_element (kept for decode experiments)
Future<void> _decodeOnly(List<String> paths, {required int inFlight}) async {
  final times = <int>[];
  var next = 0;
  final wall = Stopwatch()..start();
  var pixels = 0;
  Future<void> lane() async {
    while (next < _photos) {
      final path = paths[next++ % paths.length];
      final sw = Stopwatch()..start();
      final d = await DesktopScanItem(path).decodePixels(atLeast: 1000);
      times.add(sw.elapsedMicroseconds);
      if (d != null) pixels += d.$2 * d.$3;
    }
  }

  await Future.wait([for (var i = 0; i < inFlight; i++) lane()]);
  say(
    '  ${_stats(times)} per decode · throughput ${(wall.elapsedMilliseconds / _photos).toStringAsFixed(1)} ms/photo'
    ' · average ${(pixels / _photos / 1e6).toStringAsFixed(2)} MP decoded',
  );
}

/// The app's desktop scan loop ([ScanController] `_readDesktop`), timed.
Future<void> _pipeline(
  FaceEngine engine,
  List<String> paths, {
  required int photos,
  required int lanes,
  int atLeast = 1000,
  bool skipFaces = false,
  bool quiet = false,
  Duration previewEvery = const Duration(milliseconds: 250),
  Map<String, List<Float32List>>? prints,
}) async {
  var lastPreview = DateTime.fromMillisecondsSinceEpoch(0);
  var previews = 0;
  final main = <String, List<int>>{};
  final worker = <String, List<int>>{};
  void add(Map<String, List<int>> m, String k, int v) => (m[k] ??= []).add(v);
  var next = 0, faces = 0;
  final wall = Stopwatch()..start();
  Future<void> lane() async {
    while (next < photos) {
      final path = paths[next++ % paths.length];
      final item = DesktopScanItem(path);
      final total = Stopwatch()..start();
      final sw = Stopwatch()..start();
      final meta = item.readMeta();
      final decoded = await item.decodePixels(atLeast: atLeast);
      add(main, 'main: decode file to pixels', sw.elapsedMicroseconds);
      if (decoded == null) continue;
      final (px, w, h) = decoded;
      final full = math.max(item.size.width, item.size.height);
      final minFace = minFacePx * math.max(w, h) / math.max(1.0, math.min(1600.0, full));
      sw.reset();
      // As the app does it (ScanController._readDesktop).
      final now = DateTime.now();
      final wantPreview = now.difference(lastPreview) >= previewEvery;
      if (wantPreview) {
        lastPreview = now;
        previews++;
      }
      final scan = await engine.analyzeRgba(
        TransferableTypedData.fromList([px]),
        w,
        h,
        minFace: minFace,
        skipFaces: skipFaces,
        preview: wantPreview,
      );
      final round = sw.elapsedMicroseconds;
      final inWorker = scan?.micros?.values.fold<int>(0, (a, b) => a + b) ?? 0;
      add(main, 'main: face worker round trip', round);
      if (scan?.micros != null) {
        add(main, '  of which waiting for a free worker + transfer', round - inWorker);
        scan!.micros!.forEach((k, v) => add(worker, k, v));
      }
      faces += scan?.faces.length ?? 0;
      if (prints != null && scan != null) prints[path] = [for (final f in scan.faces) f.embedding];
      sw.reset();
      await meta;
      await item.location();
      add(main, 'main: EXIF + location (after faces)', sw.elapsedMicroseconds);
      add(main, 'main: whole photo', total.elapsedMicroseconds);
    }
  }

  await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
  if (quiet) return;
  final ms = wall.elapsedMilliseconds / photos;
  say(
    '  THROUGHPUT ${ms.toStringAsFixed(1)} ms/photo (${(1000 / ms).toStringAsFixed(1)} photos/s, '
    '${(10000 * ms / 60000).toStringAsFixed(1)} min per 10,000) · $faces faces in $photos photos · $previews previews',
  );
  for (final e in main.entries) {
    say('  ${e.key.padRight(48)} ${_stats(e.value)}');
  }
  if (worker.isNotEmpty) {
    final perPhoto = photos.toDouble();
    final sum = worker.values.expand((v) => v).fold<int>(0, (a, b) => a + b);
    say('  -- inside a face worker (average per photo; share of worker time) --');
    final rows = worker.entries.toList()
      ..sort((a, b) => b.value.fold<int>(0, (x, y) => x + y).compareTo(a.value.fold<int>(0, (x, y) => x + y)));
    for (final e in rows) {
      final t = e.value.fold<int>(0, (a, b) => a + b);
      say(
        '  ${e.key.padRight(48)} ${(t / perPhoto / 1000).toStringAsFixed(1).padLeft(6)} ms  '
        '${(100 * t / sum).toStringAsFixed(0).padLeft(3)}%',
      );
    }
  }
}

String _stats(List<int> micros) {
  if (micros.isEmpty) return '-';
  final s = [...micros]..sort();
  double ms(int us) => us / 1000;
  final avg = s.fold<int>(0, (a, b) => a + b) / s.length;
  return 'avg ${ms(avg.round()).toStringAsFixed(1).padLeft(6)} ms · median ${ms(s[s.length ~/ 2]).toStringAsFixed(1)}'
      ' · p90 ${ms(s[(s.length * 0.9).floor().clamp(0, s.length - 1)]).toStringAsFixed(1)}';
}

/// The old hash (shrink to 480, then to 9x8 with the image package) next
/// to the worker's one-pass hash, on the same decoded pixels.
// ignore: unused_element (kept for hash experiments)
Future<void> _compareHashes(FaceEngine engine, List<String> paths) async {
  final distances = <int>[];
  for (final path in paths) {
    final d = await DesktopScanItem(path).decodePixels(atLeast: 1000);
    if (d == null) continue;
    final (px, w, h) = d;
    final scan = await engine.analyzeRgba(
      TransferableTypedData.fromList([px]),
      w,
      h,
      minFace: 1e9,
      skipFaces: true,
      preview: false,
    );
    final image = img.Image.fromBytes(width: w, height: h, bytes: px.buffer, numChannels: 4);
    final k = math.min(1.0, 480 / math.max(w, h));
    final small = img.copyResize(
      image,
      width: math.max(1, (w * k).round()),
      height: math.max(1, (h * k).round()),
      interpolation: img.Interpolation.average,
    );
    final tiny = img.copyResize(small, width: 9, height: 8, interpolation: img.Interpolation.average);
    final old = differenceHash([
      for (var y = 0; y < 8; y++)
        for (var x = 0; x < 9; x++) tiny.getPixel(x, y).luminance.toInt(),
    ]);
    var diff = old ^ (scan?.hash ?? 0), bits = 0;
    while (diff != 0) {
      bits += diff & 1;
      diff = diff >>> 1;
    }
    distances.add(bits);
  }
  distances.sort();
  final same = distances.where((d) => d == 0).length;
  say(
    '  ${distances.length} photos · identical: $same · differing bits (of 64): '
    'median ${distances[distances.length ~/ 2]}, max ${distances.last} · all: $distances',
  );
}

/// The fingerprint model on its own: average time per face.
String _modelAlone(Uint8List model, {required bool gpu, required int threads, required int batch}) {
  OrtEnv.instance.init();
  try {
    final session = gpu ? LiteSession.openGpu(model) : LiteSession.open(model, threads: threads);
    final rnd = math.Random(1);
    final input = Float32List(batch * 3 * 112 * 112);
    for (var i = 0; i < input.length; i++) {
      input[i] = rnd.nextDouble() * 2 - 1;
    }
    for (var i = 0; i < 5; i++) {
      session.run(input, [batch, 3, 112, 112]);
    }
    const runs = 40;
    final sw = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      session.run(input, [batch, 3, 112, 112]);
    }
    final perFace = sw.elapsedMicroseconds / runs / batch / 1000;
    session.close();
    return '${gpu ? 'graphics chip' : 'CPU, $threads thread${threads == 1 ? '' : 's'}'}, $batch face${batch == 1 ? '' : 's'} per run: '
        '${perFace.toStringAsFixed(1)} ms per face';
  } catch (e) {
    return '${gpu ? 'graphics chip' : 'CPU $threads'} batch $batch: FAILED ${'$e'.split('\n').first}';
  } finally {
    OrtEnv.instance.release();
  }
}
