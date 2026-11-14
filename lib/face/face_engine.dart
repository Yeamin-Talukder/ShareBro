import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../data/db.dart';
import 'accel.dart';

/// InsightFace's MobileFaceNet trained on WebFace600K (`w600k_mbf` from the
/// buffalo_s pack, converted to TensorFlow Lite): a 512-number fingerprint
/// that holds up much better to glasses, angles and age than the older
/// MS-Celeb model. Research / non-commercial licence.
const _modelAsset = 'assets/models/w600k_mbf.tflite';

/// Which fingerprints the database holds; stored fingerprints from any
/// other model are redone from their face crops (see
/// [ScanController.upgradeFaces]).
const faceModelId = 'w600k_mbf';
const _crop = 112;

/// Where the eyes land in the 112x112 crop (the standard ArcFace template),
/// in image coordinates: [imageLeftEye] is the person's right eye.
const _imageLeftEye = (38.2946, 51.6963);
const _imageRightEye = (73.5318, 51.5014);

/// Faces smaller than this (in pixels of the scan image) are too blurry to
/// recognise reliably and are skipped.
const _minFacePx = 40.0;

/// Faces turned further than this (degrees) are mostly profile shots.
const _maxYaw = 50.0;

/// Scene labels less certain than this are dropped.
const _minLabelConfidence = 0.7;

/// How many faces go through the CPU before a faster chip is started: a
/// selfie or a single photo is done sooner than a GPU or NPU can warm up.
const _warmUpFaces = 4;

/// Fingerprints from another chip must point the same way as the CPU's
/// (1 is identical) before that chip is trusted with real faces.
const _sameFace = 0.999;

/// Finds faces with ML Kit and turns each into a 512-number fingerprint with
/// MobileFaceNet (InsightFace, WebFace600K). Everything runs on the device;
/// the fingerprints come from the phone's NPU or GPU when one is there and
/// quicker than the CPU (see [AccelState]).
class FaceEngine {
  FaceEngine._(this._detector, this._labeler, this._worker);

  final FaceDetector _detector;

  /// ML Kit's on-device scene labeler (beach, food, dog, …).
  final ImageLabeler _labeler;

  /// One background isolate for the whole scan. It owns the model, so the
  /// GPU and NPU are only ever touched from one place.
  final _EmbedWorker _worker;

  /// [chip] is what Settings asks for: the fastest that works, or one.
  static Future<FaceEngine> load({AccelChoice chip = AccelChoice.auto}) async {
    final model = await rootBundle.load(_modelAsset);
    final worker = await _EmbedWorker.start(_WorkerSetup(
      model: TransferableTypedData.fromList([model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes)]),
      statePath: await accelStatePath(),
      stateKey: accelStateKey(faceModelId),
      chip: chip,
    ));
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        // Eye-open and smile chances, for "eyes closed" and best-of.
        enableClassification: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.03,
      ),
    );
    final labeler = ImageLabeler(
        options: ImageLabelerOptions(confidenceThreshold: _minLabelConfidence));
    return FaceEngine._(detector, labeler, worker);
  }

  /// What's in the picture, most confident first.
  Future<List<String>> labels(String imagePath) async {
    final found = await _labeler.processImage(InputImage.fromFilePath(imagePath));
    found.sort((a, b) => b.confidence.compareTo(a.confidence));
    return [for (final l in found) l.label];
  }

  /// [imagePath] must point at an upright JPEG (no EXIF rotation needed).
  Future<List<NewFace>> analyze(String imagePath) async {
    final faces = await _detector.processImage(InputImage.fromFilePath(imagePath));
    final boxes = <_FaceBox>[];
    for (final f in faces) {
      final r = f.boundingBox;
      if (r.width < _minFacePx || r.height < _minFacePx) continue;
      if ((f.headEulerAngleY ?? 0).abs() > _maxYaw) continue;
      final le = f.landmarks[FaceLandmarkType.leftEye]?.position;
      final re = f.landmarks[FaceLandmarkType.rightEye]?.position;
      final eyeL = f.leftEyeOpenProbability, eyeR = f.rightEyeOpenProbability;
      boxes.add(_FaceBox(
        r.left, r.top, r.width, r.height,
        // ML Kit's "right eye" is the person's right, which is on the image left.
        re == null ? null : (re.x.toDouble(), re.y.toDouble()),
        le == null ? null : (le.x.toDouble(), le.y.toDouble()),
        eyesOpen: eyeL == null || eyeR == null ? (eyeL ?? eyeR) : math.min(eyeL, eyeR),
        smile: f.smilingProbability,
        yaw: f.headEulerAngleY,
      ));
    }
    if (boxes.isEmpty) return const [];
    // Android's own decoder is many times faster than decoding the JPEG in
    // Dart; only the raw pixels go to the background isolate, without a copy.
    final bytes = await File(imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final w = image.width, h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    if (data == null) return const [];
    final pixels = TransferableTypedData.fromList([data.buffer.asUint8List()]);
    return _worker.ask<List<NewFace>>(_EmbedJob(pixels, w, h, boxes));
  }

  /// Fingerprints for stored face crops (the 112x112 aligned JPEGs kept
  /// for every face), in order; null where a crop can't be read. For
  /// redoing every face after a model change without rescanning photos.
  Future<List<Float32List?>> embedCrops(List<Uint8List> jpegs) =>
      _worker.ask<List<Float32List?>>(_CropsJob(jpegs));

  void dispose() {
    _worker.stop();
    _detector.close();
    _labeler.close();
  }
}

/// What the background isolate needs to open the model.
class _WorkerSetup {
  _WorkerSetup({required this.model, required this.statePath, required this.stateKey, required this.chip});

  final TransferableTypedData model;
  final String statePath, stateKey;
  final AccelChoice chip;
}

/// Faces to cut out of a photo's [pixels] (RGBA) and fingerprint.
class _EmbedJob {
  _EmbedJob(this.pixels, this.w, this.h, this.boxes);

  final TransferableTypedData pixels;
  final int w, h;
  final List<_FaceBox> boxes;
}

/// Stored face crops to fingerprint again.
class _CropsJob {
  _CropsJob(this.jpegs);

  final List<Uint8List> jpegs;
}

/// Long-lived background isolate that turns faces into fingerprints.
class _EmbedWorker {
  _EmbedWorker._(this._inbox);

  final SendPort _inbox;

  static Future<_EmbedWorker> start(_WorkerSetup setup) async {
    final hello = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, (hello.sendPort, setup), debugName: 'faces');
    final first = await hello.first;
    if (first is SendPort) return _EmbedWorker._(first);
    isolate.kill();
    throw StateError('The face model did not load: $first');
  }

  Future<T> ask<T>(Object job) async {
    final reply = ReceivePort();
    _inbox.send((job, reply.sendPort));
    final result = await reply.first;
    if (result is T) return result;
    throw StateError('Face worker failed: $result');
  }

  /// Work already handed over is finished first; then the isolate frees
  /// the model and ends.
  void stop() => _inbox.send(null);
}

void _workerMain((SendPort, _WorkerSetup) start) {
  final (hello, setup) = start;
  final _Models models;
  try {
    models = _Models.open(setup);
  } catch (e) {
    hello.send('$e');
    return;
  }
  final inbox = ReceivePort();
  hello.send(inbox.sendPort);
  inbox.listen((message) {
    if (message == null) {
      models.close();
      inbox.close();
      return;
    }
    final (job, reply) = message as (Object, SendPort);
    try {
      reply.send(switch (job) {
        _EmbedJob() => _embed(job, models),
        _CropsJob() => _embedCrops(job.jpegs, models),
        _ => 'Unknown job',
      });
    } catch (e) {
      reply.send('$e');
    }
  });
}

/// The face model inside the background isolate: on the CPU from the start,
/// and on a faster chip once enough faces have come through to be worth
/// starting one.
class _Models {
  _Models._(this._cpu, this.layout, this._model, this._statePath, this._stateKey, this._chip);

  factory _Models.open(_WorkerSetup setup) {
    final model = setup.model.materialize().asUint8List();
    final cpu = OpenModel(model, Accel.cpu);
    final inputs = cpu.interpreter.getInputTensors();
    final output = cpu.interpreter.getOutputTensors().first.shape;
    final layout = _ModelLayout(
      inputCount: inputs.length,
      channelsFirst: inputs.first.shape[1] == 3,
      outputIs2d: output.length > 1,
      outputRows: output.length > 1 ? output[0] : 1,
      embeddingSize: output.last,
    );
    return _Models._(
        cpu, layout, setup.chip == AccelChoice.cpu ? null : model, setup.statePath, setup.stateKey, setup.chip);
  }

  final OpenModel _cpu;
  final _ModelLayout layout;
  final String _statePath, _stateKey;
  final AccelChoice _chip;

  /// The model file, kept until the chip is settled.
  Uint8List? _model;

  /// The model on the GPU or NPU, once that's been found to work.
  OpenModel? _fast;
  Accel _fastChip = Accel.cpu;
  int _faces = 0;

  /// Fingerprints for [tensors], on the best chip that's ready.
  List<Float32List> run(List<Float32List> tensors) {
    if (tensors.isEmpty) return const [];
    _faces += tensors.length;
    if (_model != null && _faces > _warmUpFaces) {
      try {
        _settle();
      } catch (_) {
        // Whatever went wrong, the CPU still works.
      }
    }
    final fast = _fast;
    if (fast != null) {
      try {
        return _runModel(fast.interpreter, tensors, layout);
      } catch (_) {
        // The chip gave up mid-scan: finish on the CPU and don't go back.
        _dropFast();
      }
    }
    return _runModel(_cpu.interpreter, tensors, layout);
  }

  /// Picks the chip for the rest of this run: tries the ones not tried
  /// before (same fingerprints as the CPU, and how fast), then starts the
  /// quickest, or the one Settings asked for.
  void _settle() {
    final model = _model!;
    _model = null;
    final state = AccelState.read(_statePath, _stateKey);
    if (state.settleCrash()) state.write(_statePath);
    final probe = [for (var k = 0; k < layout.inputCount; k++) _probeFace(k, layout.channelsFirst)];
    final truth = _runModel(_cpu.interpreter, probe, layout);
    state.ms[Accel.cpu] = _msPerFace(_cpu.interpreter, probe, layout);

    final open = <Accel, OpenModel>{};
    void tryOut(Accel chip) {
      if (chip == Accel.cpu || state.bad.contains(chip) || open.containsKey(chip)) return;
      // Only a first try leaves a mark: a chip that has worked before isn't
      // blamed when the app happens to be closed while it starts.
      if (!state.ms.containsKey(chip)) {
        state.trying = chip;
        state.write(_statePath);
      }
      OpenModel? opened;
      try {
        opened = OpenModel(model, chip);
        if (!_sameFaces(truth, _runModel(opened.interpreter, probe, layout))) {
          throw StateError('Different fingerprints');
        }
        state.ms[chip] = _msPerFace(opened.interpreter, probe, layout);
        open[chip] = opened;
      } catch (_) {
        try {
          opened?.close();
        } catch (_) {}
        state.bad.add(chip);
        state.ms.remove(chip);
      }
      state.trying = null;
      state.write(_statePath);
    }

    final only = _chip.only;
    if (only != null) {
      tryOut(only);
    } else {
      for (final chip in const [Accel.npu, Accel.gpu]) {
        if (!state.tried(chip)) tryOut(chip);
      }
    }
    final pick = only ?? state.best;
    tryOut(pick);
    state.write(_statePath);
    _fast = open.remove(pick);
    _fastChip = pick;
    for (final other in open.values) {
      other.close();
    }
  }

  void _dropFast() {
    final chip = _fastChip;
    try {
      _fast?.close();
    } catch (_) {}
    _fast = null;
    AccelState.read(_statePath, _stateKey)
      ..bad.add(chip)
      ..ms.remove(chip)
      ..write(_statePath);
  }

  void close() {
    try {
      _fast?.close();
      _cpu.close();
    } catch (_) {}
  }
}

/// A made-up face for trying a chip out: smooth shapes with a little grain,
/// the same every time.
Float32List _probeFace(int k, bool channelsFirst) {
  final rgb = Uint8List(_crop * _crop * 3);
  var grain = 12345 + k * 977;
  var o = 0;
  for (var y = 0; y < _crop; y++) {
    for (var x = 0; x < _crop; x++) {
      for (var c = 0; c < 3; c++) {
        grain = (grain * 1103515245 + 12345) & 0x7fffffff;
        final wave = math.sin(x * (0.07 + 0.02 * c) + k) * math.cos(y * 0.05 + c);
        rgb[o++] = (127.5 + 90 * wave + (grain >> 16) % 31 - 15).round().clamp(0, 255);
      }
    }
  }
  return _toTensor(rgb, channelsFirst);
}

/// Whether [got] are the same fingerprints as [truth] (both unit length).
bool _sameFaces(List<Float32List> truth, List<Float32List> got) {
  if (truth.length != got.length) return false;
  for (var i = 0; i < truth.length; i++) {
    final a = truth[i], b = got[i];
    if (a.length != b.length) return false;
    var dot = 0.0;
    for (var j = 0; j < a.length; j++) {
      dot += a[j] * b[j];
    }
    // Written this way round so "not a number" fails too.
    if (!(dot >= _sameFace)) return false;
  }
  return true;
}

/// Milliseconds a face: the middle of a few timed runs, after one more to
/// let the chip finish setting up.
double _msPerFace(Interpreter interpreter, List<Float32List> probe, _ModelLayout layout) {
  _runModel(interpreter, probe, layout);
  final watch = Stopwatch();
  final times = <int>[];
  for (var i = 0; i < 7; i++) {
    watch
      ..reset()
      ..start();
    _runModel(interpreter, probe, layout);
    watch.stop();
    times.add(watch.elapsedMicroseconds);
  }
  times.sort();
  return times[times.length ~/ 2] / 1000 / probe.length;
}

class _ModelLayout {
  _ModelLayout({
    required this.inputCount,
    required this.channelsFirst,
    required this.outputIs2d,
    required this.outputRows,
    required this.embeddingSize,
  });

  final bool outputIs2d;

  /// How many faces the model takes per run.
  final int inputCount;
  final bool channelsFirst;
  final int outputRows;
  final int embeddingSize;
}

class _FaceBox {
  _FaceBox(this.left, this.top, this.width, this.height, this.eyeL, this.eyeR,
      {this.eyesOpen, this.smile, this.yaw});

  final double left, top, width, height;
  final double? eyesOpen, smile, yaw;

  /// Eye positions as they appear in the image (left one, right one).
  final (double, double)? eyeL, eyeR;
}

/// Background-isolate work: align each face from the photo's RGBA pixels
/// and run the model.
List<NewFace> _embed(_EmbedJob job, _Models models) {
  final pixels = job.pixels.materialize().asUint8List();
  final (w, h, boxes) = (job.w, job.h, job.boxes);
  final tensors = <Float32List>[];
  final thumbs = <Uint8List>[];
  final sharpness = <double>[];
  for (final b in boxes) {
    final crop = _alignedCrop(pixels, w, h, b);
    tensors.add(_toTensor(crop, models.layout.channelsFirst));
    sharpness.add(_sharpness(crop));
    thumbs.add(img.encodeJpg(
      img.Image.fromBytes(
        width: _crop,
        height: _crop,
        bytes: crop.buffer,
        numChannels: 3,
        order: img.ChannelOrder.rgb,
      ),
      quality: 80,
    ));
  }

  final embeddings = models.run(tensors);

  return [
    for (var i = 0; i < boxes.length; i++)
      NewFace(
        left: boxes[i].left / w,
        top: boxes[i].top / h,
        width: boxes[i].width / w,
        height: boxes[i].height / h,
        embedding: embeddings[i],
        thumb: thumbs[i],
        sharpness: sharpness[i],
        eyesOpen: boxes[i].eyesOpen,
        smile: boxes[i].smile,
        yaw: boxes[i].yaw,
      ),
  ];
}

/// Fingerprints for stored face crops (already aligned 112x112 JPEGs).
List<Float32List?> _embedCrops(List<Uint8List> jpegs, _Models models) {
  final tensors = <Float32List>[];
  final ok = <int>[];
  for (final (i, j) in jpegs.indexed) {
    var face = img.decodeJpg(j);
    if (face == null) continue;
    if (face.width != _crop || face.height != _crop) {
      face = img.copyResize(face, width: _crop, height: _crop, interpolation: img.Interpolation.linear);
    }
    final rgb = Uint8List(_crop * _crop * 3);
    var o = 0;
    for (final p in face) {
      rgb[o++] = p.r.toInt();
      rgb[o++] = p.g.toInt();
      rgb[o++] = p.b.toInt();
    }
    tensors.add(_toTensor(rgb, models.layout.channelsFirst));
    ok.add(i);
  }
  final out = List<Float32List?>.filled(jpegs.length, null);
  for (final (k, e) in models.run(tensors).indexed) {
    out[ok[k]] = e;
  }
  return out;
}

/// Runs the model over [tensors], [_ModelLayout.inputCount] faces at a time.
List<Float32List> _runModel(Interpreter interpreter, List<Float32List> tensors, _ModelLayout layout) {
  if (tensors.isEmpty) return const [];
  final embeddings = <Float32List>[];
  final perRun = layout.inputCount;
  for (var start = 0; start < tensors.length; start += perRun) {
    final inputs = <Object>[
      for (var k = 0; k < perRun; k++)
        // Pad the last run by repeating a face; its result is discarded.
        tensors[math.min(start + k, tensors.length - 1)].buffer.asUint8List(),
    ];
    final out = List.generate(
        layout.outputRows, (_) => List.filled(layout.embeddingSize, 0.0));
    interpreter.runForMultipleInputs(
        inputs, {0: layout.outputIs2d ? out : out.first});
    for (var k = 0; k < layout.outputRows && start + k < tensors.length; k++) {
      embeddings.add(_normalize(out[k]));
    }
  }
  return embeddings;
}

/// Variance of the Laplacian over the face crop: blurry faces have little
/// edge detail, so they score low (roughly <60 blurry, >150 crisp).
double _sharpness(Uint8List rgb) {
  final gray = Float32List(_crop * _crop);
  for (var p = 0; p < gray.length; p++) {
    gray[p] = 0.299 * rgb[p * 3] + 0.587 * rgb[p * 3 + 1] + 0.114 * rgb[p * 3 + 2];
  }
  var sum = 0.0, sumSq = 0.0, n = 0;
  // Skip the outer band, which is mostly background after alignment.
  for (var y = 8; y < _crop - 8; y++) {
    for (var x = 8; x < _crop - 8; x++) {
      final i = y * _crop + x;
      final lap = gray[i - 1] + gray[i + 1] + gray[i - _crop] + gray[i + _crop] -
          4 * gray[i];
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}

/// Rotates and scales the face so the eyes sit where the model expects them.
/// Falls back to a square crop of the box when eyes weren't found.
Uint8List _alignedCrop(Uint8List src, int w, int h, _FaceBox b) {
  // Maps an output pixel (x, y) to a source position: src = origin + a * (q - anchor)
  // using complex multiplication, i.e. a rotation plus uniform scale.
  double ox, oy, ar, ai, qx0, qy0;
  if (b.eyeL != null && b.eyeR != null) {
    // Order the eyes by where they sit in the photo rather than trusting the
    // landmark names: if they come in swapped, the crop turns upside down.
    var (lx, ly) = b.eyeL!;
    var (rx, ry) = b.eyeR!;
    if (rx < lx) {
      (lx, ly, rx, ry) = (rx, ry, lx, ly);
    }
    final dx = rx - lx, dy = ry - ly;
    final tx = _imageRightEye.$1 - _imageLeftEye.$1;
    final ty = _imageRightEye.$2 - _imageLeftEye.$2;
    final denom = tx * tx + ty * ty;
    ar = (dx * tx + dy * ty) / denom;
    ai = (dy * tx - dx * ty) / denom;
    ox = lx;
    oy = ly;
    qx0 = _imageLeftEye.$1;
    qy0 = _imageLeftEye.$2;
  } else {
    final side = math.max(b.width, b.height);
    ar = side / _crop;
    ai = 0;
    ox = b.left + b.width / 2 - side / 2;
    oy = b.top + b.height / 2 - side / 2;
    qx0 = 0;
    qy0 = 0;
  }

  final out = Uint8List(_crop * _crop * 3);
  var o = 0;
  for (var y = 0; y < _crop; y++) {
    for (var x = 0; x < _crop; x++) {
      final qx = x - qx0, qy = y - qy0;
      final sx = ox + ar * qx - ai * qy;
      final sy = oy + ai * qx + ar * qy;
      _bilinear(src, w, h, sx, sy, out, o);
      o += 3;
    }
  }
  return out;
}

void _bilinear(Uint8List src, int w, int h, double x, double y, Uint8List out,
    int o) {
  if (x < 0 || y < 0 || x > w - 1 || y > h - 1) {
    out[o] = out[o + 1] = out[o + 2] = 0;
    return;
  }
  final x0 = x.floor(), y0 = y.floor();
  final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
  final fx = x - x0, fy = y - y0;
  final i00 = (y0 * w + x0) * 4, i10 = (y0 * w + x1) * 4;
  final i01 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4;
  for (var c = 0; c < 3; c++) {
    final top = src[i00 + c] + (src[i10 + c] - src[i00 + c]) * fx;
    final bottom = src[i01 + c] + (src[i11 + c] - src[i01 + c]) * fx;
    out[o + c] = (top + (bottom - top) * fy).round();
  }
}

/// RGB scaled to -1..1 the way InsightFace feeds its models
/// ((v - 127.5) / 127.5), in whichever channel order the model was exported
/// with.
Float32List _toTensor(Uint8List rgb, bool channelsFirst) {
  const plane = _crop * _crop;
  final t = Float32List(plane * 3);
  for (var p = 0; p < plane; p++) {
    for (var c = 0; c < 3; c++) {
      final v = (rgb[p * 3 + c] - 127.5) / 127.5;
      if (channelsFirst) {
        t[c * plane + p] = v;
      } else {
        t[p * 3 + c] = v;
      }
    }
  }
  return t;
}

Float32List _normalize(List<double> v) {
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  return Float32List.fromList([for (final x in v) n == 0 ? 0 : x / n]);
}
