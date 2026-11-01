import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../data/db.dart';

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

/// Finds faces with ML Kit and turns each into a 512-number fingerprint with
/// MobileFaceNet (InsightFace, WebFace600K). Everything runs on the device.
class FaceEngine {
  FaceEngine._(this._detector, this._labeler, this._interpreter, this._layout);

  final FaceDetector _detector;

  /// ML Kit's on-device scene labeler (beach, food, dog, …).
  final ImageLabeler _labeler;
  final Interpreter _interpreter;
  final _ModelLayout _layout;

  static Future<FaceEngine> load() async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableLandmarks: true,
        // Eye-open and smile chances, for "eyes closed" and best-of.
        enableClassification: true,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.03,
      ),
    );
    final interpreter = await Interpreter.fromAsset(
      _modelAsset,
      options: InterpreterOptions()..threads = 4,
    );
    interpreter.allocateTensors();
    final inputs = interpreter.getInputTensors();
    final output = interpreter.getOutputTensors().first.shape;
    final layout = _ModelLayout(
      address: interpreter.address,
      inputCount: inputs.length,
      channelsFirst: inputs.first.shape[1] == 3,
      outputIs2d: output.length > 1,
      outputRows: output.length > 1 ? output[0] : 1,
      embeddingSize: output.last,
    );
    final labeler = ImageLabeler(
        options: ImageLabelerOptions(confidenceThreshold: _minLabelConfidence));
    return FaceEngine._(detector, labeler, interpreter, layout);
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
    final worker = _worker ??= await (_starting ??= _EmbedWorker.start());
    return worker.run(pixels, w, h, boxes, _layout);
  }

  /// Fingerprints for stored face crops (the 112x112 aligned JPEGs kept
  /// for every face), in order; null where a crop can't be read. For
  /// redoing every face after a model change without rescanning photos.
  Future<List<Float32List?>> embedCrops(List<Uint8List> jpegs) {
    final layout = _layout;
    return Isolate.run(() => _embedCrops(jpegs, layout));
  }

  /// One background isolate for the whole scan, instead of starting (and
  /// loading the model library in) a new one for every photo.
  _EmbedWorker? _worker;
  Future<_EmbedWorker>? _starting;

  void dispose() {
    _worker?.stop();
    _detector.close();
    _labeler.close();
    _interpreter.close();
  }
}

/// Long-lived background isolate that turns face boxes into fingerprints.
class _EmbedWorker {
  _EmbedWorker._(this._isolate, this._inbox);

  final Isolate _isolate;
  final SendPort _inbox;

  static Future<_EmbedWorker> start() async {
    final hello = ReceivePort();
    final isolate = await Isolate.spawn(_workerMain, hello.sendPort, debugName: 'faces');
    final inbox = await hello.first as SendPort;
    return _EmbedWorker._(isolate, inbox);
  }

  Future<List<NewFace>> run(TransferableTypedData pixels, int w, int h,
      List<_FaceBox> boxes, _ModelLayout layout) async {
    final reply = ReceivePort();
    _inbox.send((pixels, w, h, boxes, layout, reply.sendPort));
    final result = await reply.first;
    reply.close();
    if (result is List<NewFace>) return result;
    throw StateError('Face worker failed: $result');
  }

  void stop() => _isolate.kill(priority: Isolate.immediate);
}

void _workerMain(SendPort hello) {
  final inbox = ReceivePort();
  hello.send(inbox.sendPort);
  inbox.listen((message) {
    final (pixels, w, h, boxes, layout, reply) = message as (
      TransferableTypedData,
      int,
      int,
      List<_FaceBox>,
      _ModelLayout,
      SendPort,
    );
    try {
      reply.send(_embed(pixels.materialize().asUint8List(), w, h, boxes, layout));
    } catch (e) {
      reply.send('$e');
    }
  });
}

class _ModelLayout {
  _ModelLayout({
    required this.address,
    required this.inputCount,
    required this.channelsFirst,
    required this.outputIs2d,
    required this.outputRows,
    required this.embeddingSize,
  });

  final int address;
  final bool outputIs2d;

  /// The bundled MobileFaceNet takes two faces per run (img1, img2).
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

/// Background-isolate work: align each face from the RGBA [pixels] and run
/// the model.
List<NewFace> _embed(
    Uint8List pixels, int w, int h, List<_FaceBox> boxes, _ModelLayout layout) {
  final tensors = <Float32List>[];
  final thumbs = <Uint8List>[];
  final sharpness = <double>[];
  for (final b in boxes) {
    final crop = _alignedCrop(pixels, w, h, b);
    tensors.add(_toTensor(crop, layout.channelsFirst));
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

  final embeddings = _runModel(tensors, layout);

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
List<Float32List?> _embedCrops(List<Uint8List> jpegs, _ModelLayout layout) {
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
    tensors.add(_toTensor(rgb, layout.channelsFirst));
    ok.add(i);
  }
  final out = List<Float32List?>.filled(jpegs.length, null);
  for (final (k, e) in _runModel(tensors, layout).indexed) {
    out[ok[k]] = e;
  }
  return out;
}

/// Runs the model over [tensors], [_ModelLayout.inputCount] faces at a time.
List<Float32List> _runModel(List<Float32List> tensors, _ModelLayout layout) {
  if (tensors.isEmpty) return const [];
  final interpreter = Interpreter.fromAddress(layout.address, allocated: true);
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
