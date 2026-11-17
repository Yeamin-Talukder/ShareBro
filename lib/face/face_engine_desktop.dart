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
    _DesktopSetup setup({required int threads, required bool gpu}) => _DesktopSetup(
          detector: copy(detector),
          detectorGpu: gpu ? copy(detectorGpu) : null,
          fingerprints: copy(fingerprints),
          threads: threads,
          gpu: gpu,
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
  Future<List<String>> labels(String imagePath) async => const [];

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
          {required double minFace, bool skipFaces = false}) =>
      _ask<RgbaScan>(_RgbaJob(pixels, w, h, minFace: minFace, skipFaces: skipFaces, extras: true));

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
      {required this.detector, this.detectorGpu, required this.fingerprints, required this.threads, required this.gpu});

  final TransferableTypedData detector, fingerprints;

  /// The 16-bit detector, tried on the graphics chip.
  final TransferableTypedData? detectorGpu;
  final int threads;

  /// Try the graphics chip (DirectML) first.
  final bool gpu;
}

/// Decoded pixels (RGBA) to find faces in and fingerprint; with [extras],
/// also the scan preview and the duplicate fingerprint.
class _RgbaJob {
  _RgbaJob(this.pixels, this.w, this.h, {required this.minFace, required this.skipFaces, required this.extras});

  final TransferableTypedData pixels;
  final int w, h;

  /// Faces narrower than this (in these pixels) are skipped.
  final double minFace;

  /// Faces are known already: only the preview and hash are wanted.
  final bool skipFaces;
  final bool extras;
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

RgbaScan _scanRgba(_RgbaJob job, _OnnxModels models) {
  final pixels = job.pixels.materialize().asUint8List();
  final (w, h) = (job.w, job.h);
  final faces = job.skipFaces ? const <NewFace>[] : _detectAndEmbed(pixels, w, h, models, job.minFace);
  if (!job.extras) return RgbaScan(faces, null, null);
  // The live preview and the duplicate fingerprint come from the same
  // pixels, so the photo is never decoded or encoded twice.
  final image = img.Image.fromBytes(width: w, height: h, bytes: pixels.buffer, numChannels: 4);
  final k = math.min(1.0, _previewSide / math.max(w, h));
  final small = k < 1
      ? img.copyResize(image,
          width: math.max(1, (w * k).round()), height: math.max(1, (h * k).round()), interpolation: img.Interpolation.average)
      : image;
  final preview = img.encodeJpg(small, quality: 80);
  final tiny = img.copyResize(small, width: 9, height: 8, interpolation: img.Interpolation.average);
  final hash = differenceHash([
    for (var y = 0; y < 8; y++)
      for (var x = 0; x < 9; x++) tiny.getPixel(x, y).luminance.toInt(),
  ]);
  return RgbaScan(faces, preview, hash);
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
  if (boxes.isEmpty) return const [];
  return _embedPixels(pixels, w, h, boxes, models.fingerprints);
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
    // Fingerprints stay on the CPU: the model is small (a few faces a
    // photo take milliseconds), and DirectML fails when its batch size
    // changes from photo to photo. The detector, the heavy part, always
    // sees the same 640x640 input, which suits the graphics chip.
    final fingerprints =
        LiteSession.open(setup.fingerprints.materialize().asUint8List(), threads: setup.threads, gpu: false);
    return _OnnxModels._(detector, _OnnxFingerprinter(fingerprints));
  }

  final LiteSession _detector;
  final _OnnxFingerprinter fingerprints;

  bool get onGpu => _detector.onGpu;

  List<ScrfdFace> detect(Uint8List rgba, int w, int h) {
    final box = scrfdLetterbox(rgba, w, h);
    return scrfdDecode(_detector.run(box.tensor, const [1, 3, scrfdInput, scrfdInput]), box.scale);
  }

  void close() {
    _detector.close();
    fingerprints.session.close();
    OrtEnv.instance.release();
  }
}

/// w600k_mbf in ONNX Runtime: 1..n faces of 3x112x112 in, 512 numbers each out.
class _OnnxFingerprinter implements _Fingerprinter {
  _OnnxFingerprinter(this.session);

  final LiteSession session;

  @override
  bool get channelsFirst => true;

  @override
  List<Float32List> run(List<Float32List> tensors) {
    final out = <Float32List>[];
    const size = 3 * _crop * _crop;
    for (var start = 0; start < tensors.length; start += _batch) {
      final n = math.min(_batch, tensors.length - start);
      final padded = n;
      final data = Float32List(padded * size);
      for (var k = 0; k < n; k++) {
        data.setRange(k * size, (k + 1) * size, tensors[start + k]);
      }
      final flat = session.run(data, [padded, 3, _crop, _crop]).first;
      final dim = flat.length ~/ padded;
      for (var k = 0; k < n; k++) {
        out.add(_normalize(List<double>.generate(dim, (i) => flat[k * dim + i])));
      }
    }
    return out;
  }
}
