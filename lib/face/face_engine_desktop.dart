part of 'face_engine.dart';

/// InsightFace's SCRFD-10G detector (det_10g, buffalo_l pack) and the same
/// MobileFaceNet fingerprint model the phones use (w600k_mbf, here as ONNX),
/// both research / non-commercial licence. Bundled with desktop builds only.
const _detectorAsset = 'assets/models/desktop/det_10g.onnx';

/// The same detector in 16-bit floats, for the graphics chip (about twice
/// as fast there; the CPU keeps the 32-bit one). Converted with
/// onnxconverter-common (inputs and outputs stay 32-bit); its scores match
/// the original to 0.0003 and its boxes to a tenth of a pixel.
const _detectorGpuAsset = 'assets/models/desktop/det_10g_fp16.onnx';

/// Worker counts, for measuring (`--dart-define=SB_GPU_WORKERS=2`); -1
/// means the built-in choice.
const _gpuWorkersWanted = int.fromEnvironment('SB_GPU_WORKERS', defaultValue: -1);
const _cpuWorkersWanted = int.fromEnvironment('SB_CPU_WORKERS', defaultValue: -1);
const _fingerprintAsset = 'assets/models/desktop/w600k_mbf.onnx';

/// Faces fingerprinted per model run.
const _batch = 16;

/// How the face workers run the fingerprint model. The defaults are what
/// scans use; `tool/scan_bench.dart` sets [debugFingerprintConfig] to
/// compare others.
class FingerprintConfig {
  const FingerprintConfig({this.gpu = false, this.threads, this.spin = true, this.batch = _batch});

  /// On the graphics chip (DirectML), in runs of exactly [batch] faces
  /// (padded): DirectML fails when the batch size changes between runs.
  final bool gpu;

  /// CPU threads per worker; null for the workers' own choice.
  final int? threads;

  /// Let idle CPU threads spin-wait (see [LiteSession.open]).
  final bool spin;

  /// Faces per run (the exact run size on the graphics chip).
  final int batch;

  @override
  String toString() => gpu
      ? 'graphics chip, batches of $batch'
      : 'CPU, ${threads ?? 'default'} threads, spinning ${spin ? 'on' : 'off'}, batches up to $batch';
}

/// Overrides [FingerprintConfig] for the next [FaceEngine.load] (measuring).
FingerprintConfig? debugFingerprintConfig;

/// What scans use: fingerprints on the graphics chip too, one face per run
/// (the model only takes batches of one there). Measured with
/// tool/scan_bench.dart on an i5 with Iris Xe: 57-59 ms a photo against
/// 61-67 on the CPU, where the fingerprint threads fought the decoding and
/// the other workers for cores. Identical fingerprints (similarity 1.0000).
const _fingerprintConfig = FingerprintConfig(gpu: true, batch: 1);

/// The scan preview's long side (the live view while scanning).
const _previewSide = 480;

/// The desktop engine: SCRFD finds faces and their eyes in ONNX Runtime;
/// alignment and fingerprints are the same as on the phone. Scene labels,
/// smiles and open eyes aren't read on desktop yet.
///
/// Several workers run side by side, each with its own copy of the models:
/// one on the graphics chip when the PC has a DirectML one, and one or two
/// on the CPU. A photo goes to whichever is free.
class _DesktopFaceEngine implements FaceEngine {
  _DesktopFaceEngine._(this._gpu, List<_EmbedWorker> cpu)
      : _workers = [..._gpu, ...cpu],
        _idle = [..._gpu, ...cpu];

  final List<_EmbedWorker> _gpu;
  final List<_EmbedWorker> _workers;
  final List<_EmbedWorker> _idle;
  final List<Completer<_EmbedWorker>> _waiting = [];

  /// Some of the workers run on the graphics chip.
  @override
  bool get onGpu => _gpu.isNotEmpty;

  /// Workers on the graphics chip and on the CPU, for logs.
  String get workerSummary => '${_gpu.length} on the graphics chip, ${_workers.length - _gpu.length} on the CPU';

  static Future<FaceEngine> load({AccelChoice chip = AccelChoice.auto}) async {
    final detector = await rootBundle.load(_detectorAsset);
    final detectorGpu = await rootBundle.load(_detectorGpuAsset);
    final fingerprints = await rootBundle.load(_fingerprintAsset);
    TransferableTypedData copy(ByteData d) =>
        TransferableTypedData.fromList([d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)]);
    final fp = debugFingerprintConfig ?? _fingerprintConfig;
    _DesktopSetup setup({required int threads, required bool gpu}) => _DesktopSetup(
          detector: copy(detector),
          // Core ML on a Mac picks its own precision: it gets the original.
          detectorGpu: gpu ? copy(Platform.isMacOS ? detector : detectorGpu) : null,
          fingerprints: copy(fingerprints),
          threads: threads,
          gpu: gpu,
          fpGpu: fp.gpu,
          fpThreads: fp.threads ?? threads,
          fpSpin: fp.spin,
          fpBatch: fp.batch,
        );

    // Physical cores, roughly (logical processors are usually two per core).
    final cores = math.max(1, Platform.numberOfProcessors ~/ 2);
    final gpuWorkers = <_EmbedWorker>[];
    final cpuWorkers = <_EmbedWorker>[];
    if (chip != AccelChoice.cpu && _gpuWorkersWanted != 0) {
      // Three on the graphics chip: while some do their CPU-side work
      // (letterbox, alignment, fingerprints, preview), another keeps the
      // chip busy. The detector only takes one photo per run, so this is
      // how the chip gets fed back to back. Measured on an i5-11320H with
      // Iris Xe (12 MP photos): 3 workers 100 ms/photo, 2 + 1 on the CPU
      // 128, 2 alone 144, 1 + 1 on the CPU 158.
      final wanted = _gpuWorkersWanted > 0 ? _gpuWorkersWanted : 3;
      for (var i = 0; i < wanted; i++) {
        final w = await _EmbedWorker.start(_desktopWorkerMain, setup(threads: 1, gpu: true));
        if (await w.ask<bool>(const _OnGpuJob())) {
          gpuWorkers.add(w);
        } else {
          // No usable graphics chip: this one runs on the CPU instead.
          w.stop();
          break;
        }
      }
    }
    final gpu = gpuWorkers.isNotEmpty;
    // CPU workers share the cores. Next to graphics-chip workers none: they
    // need the CPU for their own side of the work, and an extra CPU worker
    // made scans slower. Without a graphics chip, two that split the cores,
    // so one computes while the other aligns or encodes.
    var cpuCount = _cpuWorkersWanted >= 0 ? _cpuWorkersWanted : (gpu ? 0 : (cores >= 3 ? 2 : 1));
    // Never no workers at all: scans would wait forever.
    if (!gpu && cpuCount == 0) cpuCount = 1;
    final threads = gpu ? math.max(1, cores ~/ 2) : math.max(1, cores ~/ math.max(1, cpuCount));
    for (var i = 0; i < cpuCount; i++) {
      cpuWorkers.add(await _EmbedWorker.start(_desktopWorkerMain, setup(threads: threads, gpu: false)));
    }
    return _DesktopFaceEngine._(gpuWorkers, cpuWorkers);
  }

  Future<T> _ask<T>(Object job) async {
    final w = _idle.isNotEmpty ? _idle.removeAt(0) : await (_waiting..add(Completer())).last.future;
    try {
      return await w.ask<T>(job);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(w);
      } else {
        // Graphics-chip workers are faster: they go to the front, so the
        // next photo goes to one of them when it's free.
        _gpu.contains(w) ? _idle.insert(0, w) : _idle.add(w);
      }
    }
  }

  /// How many photos can be in face detection at once.
  @override
  int get parallel => _workers.length;

  @override
  int get gpuLanes => 0;

  @override
  Future<List<String>> labels(String imagePath) async => const [];

  /// Desktop workers pick their own chip; this is only for phones.
  @override
  Future<List<NewFace>> analyzeOnGpu(String imagePath) => analyze(imagePath);

  @override
  Future<List<NewFace>> analyze(String imagePath) async {
    final decoded = await _decodeRgba(imagePath);
    if (decoded == null) return const [];
    final (pixels, w, h) = decoded;
    final scan = await _ask<RgbaScan>(_RgbaJob(pixels, w, h, minFace: _minFacePx, skipFaces: false, extras: false));
    return scan.faces;
  }

  @override
  Future<RgbaScan?> analyzeRgba(TransferableTypedData pixels, int w, int h,
          {required double minFace, bool skipFaces = false, bool preview = true}) =>
      _ask<RgbaScan>(
          _RgbaJob(pixels, w, h, minFace: minFace, skipFaces: skipFaces, extras: true, preview: preview));

  @override
  Future<List<Float32List?>> embedCrops(List<Uint8List> jpegs) => _ask<List<Float32List?>>(_CropsJob(jpegs));

  @override
  void dispose() {
    for (final w in _workers) {
      w.stop();
    }
  }
}

class _DesktopSetup {
  _DesktopSetup(
      {required this.detector,
      this.detectorGpu,
      required this.fingerprints,
      required this.threads,
      required this.gpu,
      this.fpGpu = false,
      required this.fpThreads,
      this.fpSpin = true,
      this.fpBatch = _batch});

  /// The fingerprint model's [FingerprintConfig].
  final bool fpGpu, fpSpin;
  final int fpThreads, fpBatch;

  final TransferableTypedData detector, fingerprints;

  /// The 16-bit detector, tried on the graphics chip.
  final TransferableTypedData? detectorGpu;
  final int threads;

  /// Try the graphics chip (DirectML) first.
  final bool gpu;
}

/// Decoded pixels (RGBA) to find faces in and fingerprint; with [extras],
/// also the duplicate fingerprint and (with [preview]) the scan preview.
class _RgbaJob {
  _RgbaJob(this.pixels, this.w, this.h,
      {required this.minFace, required this.skipFaces, required this.extras, this.preview = true});

  final TransferableTypedData pixels;
  final int w, h;

  /// Faces narrower than this (in these pixels) are skipped.
  final double minFace;

  /// Faces are known already: only the preview and hash are wanted.
  final bool skipFaces;
  final bool extras;

  /// Make the live-view JPEG too. Scans ask for one only a few times a
  /// second: shrinking and encoding it took about a third of a worker's
  /// time when every photo had one.
  final bool preview;
}

/// "Are you on the graphics chip?"
class _OnGpuJob {
  const _OnGpuJob();
}

void _desktopWorkerMain((SendPort, _DesktopSetup) start) {
  final (hello, setup) = start;
  final _OnnxModels models;
  try {
    models = _OnnxModels.open(setup);
  } catch (e) {
    hello.send('$e');
    return;
  }
  _serve(
    hello,
    (job) => switch (job) {
      _RgbaJob() => _scanRgba(job, models),
      _CropsJob() => _embedCrops(job.jpegs, models.fingerprints),
      _OnGpuJob() => models.onGpu,
      _ => 'Unknown job',
    },
    models.close,
  );
}

/// Stage timings for measuring scans (`--dart-define=SB_SCAN_TIMING=true`);
/// compiled out otherwise.
const scanTiming = bool.fromEnvironment('SB_SCAN_TIMING');

/// This worker's time per stage for the current photo, in microseconds.
final _stageMicros = <String, int>{};
final _stageClock = Stopwatch();

/// Adds the time since the last mark to [stage].
void _mark(String stage) {
  if (!scanTiming) return;
  _stageMicros[stage] = (_stageMicros[stage] ?? 0) + _stageClock.elapsedMicroseconds;
  _stageClock.reset();
}

RgbaScan _scanRgba(_RgbaJob job, _OnnxModels models) {
  if (scanTiming) {
    _stageMicros.clear();
    _stageClock
      ..reset()
      ..start();
  }
  final pixels = job.pixels.materialize().asUint8List();
  _mark('worker: receive pixels');
  final (w, h) = (job.w, job.h);
  final faces = job.skipFaces ? const <NewFace>[] : _detectAndEmbed(pixels, w, h, models, job.minFace);
  if (!job.extras) return RgbaScan(faces, null, null, micros: scanTiming ? Map.of(_stageMicros) : null);
  // The live preview and the duplicate fingerprint come from the same
  // pixels, so the photo is never decoded or encoded twice.
  final hash = rgbaHash(pixels, w, h);
  _mark('worker: duplicate hash');
  Uint8List? preview;
  if (job.preview) {
    final image = img.Image.fromBytes(width: w, height: h, bytes: pixels.buffer, numChannels: 4);
    final k = math.min(1.0, _previewSide / math.max(w, h));
    final small = k < 1
        ? img.copyResize(image,
            width: math.max(1, (w * k).round()),
            height: math.max(1, (h * k).round()),
            interpolation: img.Interpolation.average)
        : image;
    _mark('worker: preview resize');
    preview = img.encodeJpg(small, quality: 80);
    _mark('worker: preview JPEG');
  }
  return RgbaScan(faces, preview, hash, micros: scanTiming ? Map.of(_stageMicros) : null);
}

/// The duplicate fingerprint (see [differenceHash]) straight from RGBA
/// pixels: the photo averaged into 9x8 blocks in one pass, then each
/// block's brightness. Much cheaper than shrinking it first; large photos
/// use every second pixel each way, which doesn't change a 9x8 average.
int rgbaHash(Uint8List rgba, int w, int h) {
  final step = w * h > 1000000 ? 2 : 1;
  final r = Int32List(72), g = Int32List(72), b = Int32List(72), n = Int32List(72);
  final colBin = Int32List(w);
  for (var x = 0; x < w; x++) {
    colBin[x] = math.min(8, x * 9 ~/ w);
  }
  for (var y = 0; y < h; y += step) {
    final row = math.min(7, y * 8 ~/ h) * 9;
    final rowStart = y * w * 4;
    for (var x = 0; x < w; x += step) {
      final i = rowStart + x * 4;
      final k = row + colBin[x];
      r[k] += rgba[i];
      g[k] += rgba[i + 1];
      b[k] += rgba[i + 2];
      n[k]++;
    }
  }
  return differenceHash([
    for (var k = 0; k < 72; k++)
      n[k] == 0 ? 0 : ((0.299 * r[k] + 0.587 * g[k] + 0.114 * b[k]) / n[k]).toInt(),
  ]);
}

List<NewFace> _detectAndEmbed(Uint8List pixels, int w, int h, _OnnxModels models, double minFace) {
  final boxes = <_FaceBox>[];
  for (final f in models.detect(pixels, w, h)) {
    // Boxes can reach past the photo's edge; keep them inside it.
    final left = f.left.clamp(0.0, w.toDouble()), top = f.top.clamp(0.0, h.toDouble());
    final width = f.right.clamp(0.0, w.toDouble()) - left;
    final height = f.bottom.clamp(0.0, h.toDouble()) - top;
    if (width < minFace || height < minFace) continue;
    if (f.yaw.abs() > _maxYaw) continue;
    boxes.add(_FaceBox(left, top, width, height, f.points[0], f.points[1], yaw: f.yaw));
  }
  _mark('worker: detect (decode output)');
  if (boxes.isEmpty) return const [];
  final faces = _embedPixels(pixels, w, h, boxes, models.fingerprints);
  _mark('worker: align faces + thumbnails');
  return faces;
}

/// Both models, open in the background isolate.
class _OnnxModels {
  _OnnxModels._(this._detector, this.fingerprints);

  factory _OnnxModels.open(_DesktopSetup setup) {
    OrtEnv.instance.init();
    LiteSession? detector;
    final gpuModel = setup.detectorGpu;
    if (setup.gpu && gpuModel != null) {
      try {
        detector = LiteSession.openGpu(gpuModel.materialize().asUint8List());
      } catch (_) {
        // No usable graphics chip: the 32-bit model on the CPU below.
      }
    }
    detector ??= LiteSession.open(setup.detector.materialize().asUint8List(), threads: setup.threads);
    // Fingerprints: on the CPU always, and on the graphics chip too when
    // the detector got there and the chip's answers match the CPU's on two
    // test faces. DirectML only takes this model one face per run.
    final fpModel = setup.fingerprints.materialize().asUint8List();
    final cpuPrints = _OnnxFingerprinter(LiteSession.open(fpModel, threads: setup.fpThreads, spin: setup.fpSpin));
    if (setup.fpGpu && detector.onGpu) {
      _OnnxFingerprinter? gpuPrints;
      try {
        gpuPrints = _OnnxFingerprinter(LiteSession.openGpu(fpModel), batch: setup.fpBatch, fixed: true);
        final probe = [_probeFace(0, true), _probeFace(1, true)];
        if (_sameFaces(cpuPrints.run(probe), gpuPrints.run(probe))) {
          return _OnnxModels._(detector, gpuPrints..fallback = cpuPrints);
        }
        debugPrint('Face fingerprints: the graphics chip disagreed with the CPU, using the CPU');
      } catch (e) {
        debugPrint('Face fingerprints: graphics chip unavailable ($e), using the CPU');
      }
      gpuPrints?.close();
    }
    return _OnnxModels._(detector, cpuPrints);
  }

  final LiteSession _detector;
  final _OnnxFingerprinter fingerprints;

  bool get onGpu => _detector.onGpu;

  List<ScrfdFace> detect(Uint8List rgba, int w, int h) {
    final box = scrfdLetterbox(rgba, w, h);
    _mark('worker: letterbox to 640');
    final out = _detector.run(box.tensor, const [1, 3, scrfdInput, scrfdInput]);
    _mark(onGpu ? 'worker: detector model (GPU)' : 'worker: detector model (CPU)');
    return scrfdDecode(out, box.scale);
  }

  void close() {
    _detector.close();
    fingerprints.close();
    OrtEnv.instance.release();
  }
}

/// w600k_mbf in ONNX Runtime: 1..n faces of 3x112x112 in, 512 numbers each out.
class _OnnxFingerprinter implements _Fingerprinter {
  _OnnxFingerprinter(this.session, {this.batch = _batch, this.fixed = false});

  LiteSession session;

  /// Faces per run; with [fixed], every run is exactly this many (padded
  /// with blank faces), as the graphics chip needs.
  int batch;
  bool fixed;

  /// The CPU copy to switch to for good if the graphics chip fails a run
  /// (a driver reset, say), so a long scan carries on.
  _OnnxFingerprinter? fallback;

  void close() {
    session.close();
    fallback?.close();
  }

  @override
  List<Float32List> run(List<Float32List> tensors) {
    final cpu = fallback;
    if (cpu == null) return _run(tensors);
    try {
      return _run(tensors);
    } catch (e) {
      debugPrint('Face fingerprints: the graphics chip failed ($e), switching to the CPU');
      session.close();
      session = cpu.session;
      batch = cpu.batch;
      fixed = cpu.fixed;
      fallback = null;
      return _run(tensors);
    }
  }

  @override
  bool get channelsFirst => true;

  List<Float32List> _run(List<Float32List> tensors) {
    final out = <Float32List>[];
    const size = 3 * _crop * _crop;
    for (var start = 0; start < tensors.length; start += batch) {
      final n = math.min(batch, tensors.length - start);
      final padded = fixed ? batch : n;
      final data = Float32List(padded * size);
      for (var k = 0; k < n; k++) {
        data.setRange(k * size, (k + 1) * size, tensors[start + k]);
      }
      _mark('worker: align faces + thumbnails');
      final flat = session.run(data, [padded, 3, _crop, _crop]).first;
      _mark('worker: fingerprint model');
      final dim = flat.length ~/ padded;
      for (var k = 0; k < n; k++) {
        out.add(_normalize(List<double>.generate(dim, (i) => flat[k * dim + i])));
      }
    }
    return out;
  }
}
