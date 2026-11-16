part of 'face_engine.dart';

/// InsightFace's SCRFD-10G detector (det_10g, buffalo_l pack) and the same
/// MobileFaceNet fingerprint model the phones use (w600k_mbf, here as ONNX),
/// both research / non-commercial licence. Bundled with desktop builds only.
const _detectorAsset = 'assets/models/desktop/det_10g.onnx';
const _fingerprintAsset = 'assets/models/desktop/w600k_mbf.onnx';

/// Faces fingerprinted per model run.
const _batch = 16;

/// The desktop engine: SCRFD finds faces and their eyes in ONNX Runtime;
/// alignment and fingerprints are the same as on the phone. Scene labels,
/// smiles and open eyes aren't read on desktop yet.
class _DesktopFaceEngine implements FaceEngine {
  _DesktopFaceEngine._(this._worker);

  final _EmbedWorker _worker;

  static Future<FaceEngine> load() async {
    Future<TransferableTypedData> asset(String name) async {
      final d = await rootBundle.load(name);
      return TransferableTypedData.fromList([d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)]);
    }

    final setup = _DesktopSetup(
      detector: await asset(_detectorAsset),
      fingerprints: await asset(_fingerprintAsset),
      threads: math.max(1, math.min(8, Platform.numberOfProcessors ~/ 2)),
    );
    return _DesktopFaceEngine._(await _EmbedWorker.start(_desktopWorkerMain, setup));
  }

  @override
  Future<List<String>> labels(String imagePath) async => const [];

  @override
  Future<List<NewFace>> analyze(String imagePath) async {
    final decoded = await _decodeRgba(imagePath);
    if (decoded == null) return const [];
    final (pixels, w, h) = decoded;
    return _worker.ask<List<NewFace>>(_DesktopJob(pixels, w, h));
  }

  @override
  Future<List<Float32List?>> embedCrops(List<Uint8List> jpegs) =>
      _worker.ask<List<Float32List?>>(_CropsJob(jpegs));

  @override
  void dispose() => _worker.stop();
}

class _DesktopSetup {
  _DesktopSetup({required this.detector, required this.fingerprints, required this.threads});

  final TransferableTypedData detector, fingerprints;
  final int threads;
}

/// A whole photo (RGBA) to find faces in and fingerprint.
class _DesktopJob {
  _DesktopJob(this.pixels, this.w, this.h);

  final TransferableTypedData pixels;
  final int w, h;
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
      _DesktopJob() => _detectAndEmbed(job, models),
      _CropsJob() => _embedCrops(job.jpegs, models.fingerprints),
      _ => 'Unknown job',
    },
    models.close,
  );
}

List<NewFace> _detectAndEmbed(_DesktopJob job, _OnnxModels models) {
  final pixels = job.pixels.materialize().asUint8List();
  final (w, h) = (job.w, job.h);
  final boxes = <_FaceBox>[];
  for (final f in models.detect(pixels, w, h)) {
    // Boxes can reach past the photo's edge; keep them inside it.
    final left = f.left.clamp(0.0, w.toDouble()), top = f.top.clamp(0.0, h.toDouble());
    final width = f.right.clamp(0.0, w.toDouble()) - left;
    final height = f.bottom.clamp(0.0, h.toDouble()) - top;
    if (width < _minFacePx || height < _minFacePx) continue;
    if (f.yaw.abs() > _maxYaw) continue;
    boxes.add(_FaceBox(left, top, width, height, f.points[0], f.points[1], yaw: f.yaw));
  }
  if (boxes.isEmpty) return const [];
  return _embedPixels(pixels, w, h, boxes, models.fingerprints);
}

/// Both models, open in the background isolate.
class _OnnxModels {
  _OnnxModels._(this._detector, this.fingerprints, this._options);

  factory _OnnxModels.open(_DesktopSetup setup) {
    OrtEnv.instance.init();
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(setup.threads)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    final detector = OrtSession.fromBuffer(setup.detector.materialize().asUint8List(), options);
    final fingerprints = OrtSession.fromBuffer(setup.fingerprints.materialize().asUint8List(), options);
    return _OnnxModels._(detector, _OnnxFingerprinter(fingerprints), options);
  }

  final OrtSession _detector;
  final _OnnxFingerprinter fingerprints;
  final OrtSessionOptions _options;

  List<ScrfdFace> detect(Uint8List rgba, int w, int h) {
    final box = scrfdLetterbox(rgba, w, h);
    final input = OrtValueTensor.createTensorWithDataList(box.tensor, [1, 3, scrfdInput, scrfdInput]);
    final run = OrtRunOptions();
    final outputs = _detector.run(run, {_detector.inputNames.first: input});
    try {
      return scrfdDecode([for (final o in outputs) _flatten(o!.value)], box.scale);
    } finally {
      input.release();
      run.release();
      for (final o in outputs) {
        o?.release();
      }
    }
  }

  void close() {
    _detector.release();
    fingerprints.session.release();
    _options.release();
    OrtEnv.instance.release();
  }
}

/// w600k_mbf in ONNX Runtime: 1..n faces of 3x112x112 in, 512 numbers each out.
class _OnnxFingerprinter implements _Fingerprinter {
  _OnnxFingerprinter(this.session);

  final OrtSession session;

  @override
  bool get channelsFirst => true;

  @override
  List<Float32List> run(List<Float32List> tensors) {
    final out = <Float32List>[];
    const size = 3 * _crop * _crop;
    for (var start = 0; start < tensors.length; start += _batch) {
      final n = math.min(_batch, tensors.length - start);
      final data = Float32List(n * size);
      for (var k = 0; k < n; k++) {
        data.setRange(k * size, (k + 1) * size, tensors[start + k]);
      }
      final input = OrtValueTensor.createTensorWithDataList(data, [n, 3, _crop, _crop]);
      final run = OrtRunOptions();
      final outputs = session.run(run, {session.inputNames.first: input});
      try {
        final rows = outputs.first!.value as List;
        for (final row in rows) {
          out.add(_normalize([for (final v in row as List) (v as num).toDouble()]));
        }
      } finally {
        input.release();
        run.release();
        for (final o in outputs) {
          o?.release();
        }
      }
    }
    return out;
  }
}

/// ONNX Runtime hands tensors back as nested lists; the decoder wants them flat.
Float32List _flatten(Object? value) {
  final out = <double>[];
  void walk(Object? v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final x in v) {
        walk(x);
      }
    }
  }

  walk(value);
  return Float32List.fromList(out);
}
