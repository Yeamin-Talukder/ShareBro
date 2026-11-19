part of 'face_engine.dart';

/// InsightFace's small SCRFD face finder (det_500m, buffalo_sc pack, the
/// same family the desktop uses), converted to TensorFlow Lite with 16-bit
/// weights for phone graphics chips. Research / non-commercial licence.
const _gpuFinderAsset = 'assets/models/face_finder_gpu.tflite';

/// Changes when the model does, so it's tried afresh.
const _gpuFinderId = 'scrfd_500m';

/// Photos that may be with the graphics-chip face finder at once: while one
/// is on the chip, the next is being decoded. Settable for measuring
/// (`--dart-define=SB_PHONE_GPU_LANES=1`).
const _gpuLanesWanted = int.fromEnvironment('SB_PHONE_GPU_LANES', defaultValue: 2);

/// Graphics-chip answers that differ from the CPU's by more than these
/// mean the chip isn't trusted. Scores are 0..1; box and landmark distances
/// are in grid cells (8 to 32 pixels of the 640 picture), relative above 1.
/// The 16-bit model already differs from the original by about 0.01 in
/// scores and 0.07 in distances, which moves boxes a tenth of a pixel; a
/// broken chip is far off, or not a number.
const _gpuFinderScoreTolerance = 0.05;
const _gpuFinderDistanceTolerance = 0.25;

/// The graphics-chip face finder failing this many photos in a row stops it
/// for the rest of the scan; ML Kit carries on alone.
const _gpuFinderMaxFailures = 3;

/// Where what's known about the graphics-chip face finder is kept (worked,
/// didn't, or took the app down while starting): see [AccelState].
Future<String> gpuFinderStatePath() async => p.join((await appDataDir()).path, 'face_finder_gpu.json');

String gpuFinderStateKey() => accelStateKey(_gpuFinderId);

/// Phones: a second face finder that runs on the graphics chip, next to ML
/// Kit on the CPU, so both chips find faces at the same time. Faces it finds
/// go through the same fingerprint model, so they match ML Kit's.
class _GpuFinder {
  _GpuFinder._(this._worker, this.msPerPhoto);

  final _EmbedWorker _worker;

  /// How long the chip takes for one photo, measured when it started.
  final double msPerPhoto;

  int _failures = 0;
  bool _stopped = false;

  bool get working => !_stopped;

  /// Starts it, or null where the graphics chip didn't work before, doesn't
  /// work now, or gives different answers from the CPU. A first try is
  /// marked before it starts, so a crash while starting is remembered.
  static Future<_GpuFinder?> start() async {
    final path = await gpuFinderStatePath();
    final state = AccelState.read(path, gpuFinderStateKey());
    if (state.settleCrash()) state.write(path);
    if (state.bad.contains(Accel.gpu)) return null;
    final first = !state.ms.containsKey(Accel.gpu);
    if (first) {
      state.trying = Accel.gpu;
      state.write(path);
    }
    _EmbedWorker? worker;
    try {
      final model = await rootBundle.load(_gpuFinderAsset);
      worker = await _EmbedWorker.start(
        _gpuFinderMain,
        TransferableTypedData.fromList([model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes)]),
      );
      final ms = await worker.ask<double>(const _HowFastJob());
      state
        ..ms[Accel.gpu] = ms
        ..finished(Accel.gpu)
        ..trying = null
        ..write(path);
      return _GpuFinder._(worker, ms);
    } catch (e) {
      debugPrint('Graphics-chip face finder not used: $e');
      worker?.stop();
      state
        ..bad.add(Accel.gpu)
        ..ms.remove(Accel.gpu)
        ..trying = null
        ..write(path);
      return null;
    }
  }

  /// The faces in decoded RGBA pixels, with eyes for alignment, and the
  /// pixels handed back for fingerprinting.
  Future<_Found> find(TransferableTypedData pixels, int w, int h) async {
    if (_stopped) throw StateError('The graphics-chip face finder stopped');
    try {
      final found = await _worker.ask<_Found>(_FindJob(pixels, w, h));
      _failures = 0;
      return found;
    } catch (_) {
      if (++_failures >= _gpuFinderMaxFailures) stop();
      rethrow;
    }
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _worker.stop();
  }
}

/// Decoded pixels to find faces in.
class _FindJob {
  _FindJob(this.pixels, this.w, this.h);

  final TransferableTypedData pixels;
  final int w, h;
}

/// "How long does a photo take on your chip?"
class _HowFastJob {
  const _HowFastJob();
}

/// What the finder answers: faces to fingerprint, and the pixels back.
class _Found {
  _Found(this.boxes, this.pixels);

  final List<_FaceBox> boxes;
  final TransferableTypedData pixels;
}

void _gpuFinderMain((SendPort, TransferableTypedData) start) {
  final (hello, model) = start;
  final _ScrfdLite finder;
  try {
    finder = _ScrfdLite.open(model.materialize().asUint8List());
  } catch (e) {
    hello.send('$e');
    return;
  }
  _serve(
    hello,
    (job) => switch (job) {
      _FindJob() => finder.find(job),
      _HowFastJob() => finder.msPerPhoto,
      _ => 'Unknown job',
    },
    finder.close,
  );
}

/// SCRFD in TensorFlow Lite on the graphics chip, inside its own isolate.
class _ScrfdLite {
  _ScrfdLite._(this._model, this._order, this.msPerPhoto);

  /// Opens the model on the graphics chip and checks it against the CPU on
  /// a made-up picture: same scores, boxes and landmarks, near enough.
  factory _ScrfdLite.open(Uint8List bytes) {
    final gpu = OpenModel(bytes, Accel.gpu, threads: 1);
    try {
      final order = _outputOrder(gpu.interpreter);
      final probe = _finderProbe();
      final onGpu = _runFinder(gpu.interpreter, order, probe);
      final cpu = OpenModel(bytes, Accel.cpu, threads: 2);
      try {
        final truth = _runFinder(cpu.interpreter, order, probe);
        for (var i = 0; i < truth.length; i++) {
          for (var j = 0; j < truth[i].length; j++) {
            final t = truth[i][j];
            final d = (t - onGpu[i][j]).abs();
            // Written this way round so "not a number" fails too.
            final allowed = i < 3 ? _gpuFinderScoreTolerance : _gpuFinderDistanceTolerance * math.max(1, t.abs());
            if (!(d <= allowed)) {
              throw StateError('The graphics chip gives different faces');
            }
          }
        }
      } finally {
        cpu.close();
      }
      // The middle of a few timed runs.
      final times = <int>[];
      final watch = Stopwatch();
      for (var i = 0; i < 5; i++) {
        watch
          ..reset()
          ..start();
        _runFinder(gpu.interpreter, order, probe);
        watch.stop();
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      return _ScrfdLite._(gpu, order, times[times.length ~/ 2] / 1000);
    } catch (_) {
      gpu.close();
      rethrow;
    }
  }

  final OpenModel _model;

  /// Which output holds what, in [scrfdDecode]'s order.
  final List<int> _order;
  final double msPerPhoto;

  _Found find(_FindJob job) {
    final pixels = job.pixels.materialize().asUint8List();
    final (w, h) = (job.w, job.h);
    final box = scrfdLetterbox(pixels, w, h, channelsLast: true);
    final boxes = <_FaceBox>[];
    for (final f in scrfdDecode(_runFinder(_model.interpreter, _order, box.tensor), box.scale)) {
      // The same rules as the other face finders: inside the photo, big
      // enough to recognise, not turned to the side.
      final left = f.left.clamp(0.0, w.toDouble()), top = f.top.clamp(0.0, h.toDouble());
      final width = f.right.clamp(0.0, w.toDouble()) - left;
      final height = f.bottom.clamp(0.0, h.toDouble()) - top;
      if (width < _minFacePx || height < _minFacePx) continue;
      if (f.yaw.abs() > _maxYaw) continue;
      boxes.add(_FaceBox(left, top, width, height, f.points[0], f.points[1], yaw: f.yaw));
    }
    return _Found(boxes, TransferableTypedData.fromList([pixels]));
  }

  void close() => _model.close();
}

/// The converted model's outputs come in its own order; SCRFD's decoder
/// wants scores, then boxes, then landmarks, each for grid steps 8, 16 and
/// 32. Each output's size says which it is: values per anchor (1, 4 or 10)
/// and anchors (two per grid cell).
List<int> _outputOrder(Interpreter interpreter) {
  final outputs = interpreter.getOutputTensors();
  final order = List<int>.filled(9, -1);
  for (final (i, t) in outputs.indexed) {
    final shape = t.shape;
    final per = shape.last;
    final anchors = shape.fold<int>(1, (a, b) => a * b) ~/ per;
    final kind = switch (per) { 1 => 0, 4 => 1, 10 => 2, _ => -1 };
    final step = switch (anchors) { 12800 => 0, 3200 => 1, 800 => 2, _ => -1 };
    if (kind < 0 || step < 0) throw StateError('Unexpected face finder output $shape');
    order[kind * 3 + step] = i;
  }
  if (order.contains(-1)) throw StateError('Face finder outputs missing');
  return order;
}

/// Runs the finder on a letterboxed picture; the outputs in [scrfdDecode]'s
/// order.
List<Float32List> _runFinder(Interpreter interpreter, List<int> order, Float32List input) {
  interpreter.runInference([input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes)]);
  final outputs = interpreter.getOutputTensors();
  return [
    for (final i in order)
      () {
        final data = outputs[i].data;
        return Float32List.fromList(data.buffer.asFloat32List(data.offsetInBytes, data.lengthInBytes ~/ 4));
      }(),
  ];
}

/// A made-up picture with soft shapes and a little grain, the same every
/// time, in the finder's input layout.
Float32List _finderProbe() {
  final t = Float32List(scrfdInput * scrfdInput * 3);
  var grain = 4242;
  var o = 0;
  for (var y = 0; y < scrfdInput; y++) {
    for (var x = 0; x < scrfdInput; x++) {
      for (var c = 0; c < 3; c++) {
        grain = (grain * 1103515245 + 12345) & 0x7fffffff;
        final wave = math.sin(x * (0.031 + 0.01 * c)) * math.cos(y * 0.027 + c);
        final v = (127.5 + 100 * wave + (grain >> 16) % 21 - 10).clamp(0, 255);
        t[o++] = (v - 127.5) / 128;
      }
    }
  }
  return t;
}
