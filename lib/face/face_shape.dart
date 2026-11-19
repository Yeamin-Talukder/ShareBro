import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart' show OrtEnv;
import 'package:photo_manager/photo_manager.dart' show AssetEntity, ThumbnailSize;
import 'package:tflite_flutter/tflite_flutter.dart' show Interpreter, InterpreterOptions;

import '../data/db.dart';
import '../platform/device.dart';
import 'ort_lite.dart';

/// A person's real face shape, for the 3D face model on their page: 468
/// points (x, y, z) on the face, averaged from their clearest photos.
///
/// Google's MediaPipe face-landmark model (Apache-2.0, converted to ONNX)
/// reads the points from each face. The face is cut out of the photo with
/// room around it and turned so the eyes are level, as the model expects;
/// each result is then turned to face straight ahead, centred between the
/// eyes and scaled so the eyes are one unit apart, and the results are
/// averaged so no single expression or angle bends the shape.
///
/// Everything happens on this computer; the shape is kept in the database
/// and never sent anywhere (not even by Sync people).
abstract final class FaceShape {
  static const points = 468;
  /// The same model: converted to ONNX for computers, Google's own
  /// TFLite file on phones.
  static String get _asset =>
      Device.desktop ? 'assets/models/desktop/face_landmark.onnx' : 'assets/models/face_landmark.tflite';
  static const _side = 192;

  /// Remake the shape once the person has this many more faces (or a
  /// fifth more) than when it was made.
  static bool stale({required int faceCount, required int madeWith}) =>
      faceCount >= madeWith + math.max(8, madeWith ~/ 5);

  /// Indices of landmarks used to straighten a face: the outer corners of
  /// the eyes (the left and right one in the picture), forehead and chin.
  static const eyeLeft = 33, eyeRight = 263, forehead = 10, chin = 152;

  /// Works out [personId]'s shape and saves it. Null when no face could be
  /// read (too few, too small or too turned).
  static Future<Float32List?> build(AppDb db, int personId) async {
    final faces = await db.shapeFaces(personId, limit: 20);
    if (faces.isEmpty) return null;
    final model = await rootBundle.load(_asset);
    final modelBytes = model.buffer.asUint8List(model.offsetInBytes, model.lengthInBytes);

    // First look: the stored box, with room around it.
    final first = <_Crop>[];
    for (final f in faces) {
      final photo = await _open(f.assetId);
      if (photo == null) continue;
      final w = photo.width.toDouble(), h = photo.height.toDouble();
      final cx = (f.left + f.width / 2) * w, cy = (f.top + f.height / 2) * h;
      final side = math.max(f.width * w, f.height * h) * 1.5;
      // Too small to read a shape from.
      if (side < 72) {
        photo.dispose();
        continue;
      }
      final crop = _Crop(f.assetId, photo, cx, cy, side, 0);
      crop.rgba = await crop.render();
      first.add(crop);
    }
    if (first.isEmpty) return null;
    // Only plain pixels go to the worker (an opened photo can't).
    final firstPixels = [for (final c in first) c.rgba!];
    final phone = !Device.desktop;
    final seen = await Isolate.run(() => _read(modelBytes, firstPixels, canonical: false, phone: phone));

    // Second look: centred on the face the model found, eyes level.
    final second = <_Crop>[];
    for (final (i, c) in first.indexed) {
      final p = seen[i];
      if (p == null) {
        c.photo.dispose();
        continue;
      }
      final k = c.side / _side;
      ui.Offset photoPoint(int j) {
        // Crop pixels back to the photo (the first crop isn't turned).
        return ui.Offset(c.cx - c.side / 2 + p[j * 3] * k, c.cy - c.side / 2 + p[j * 3 + 1] * k);
      }

      final a = photoPoint(eyeLeft), b = photoPoint(eyeRight);
      var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      for (var j = 0; j < points; j++) {
        final q = photoPoint(j);
        minX = math.min(minX, q.dx);
        maxX = math.max(maxX, q.dx);
        minY = math.min(minY, q.dy);
        maxY = math.max(maxY, q.dy);
      }
      final turned = _Crop(c.assetId, c.photo, (minX + maxX) / 2, (minY + maxY) / 2,
          math.max(maxX - minX, maxY - minY) * 1.5, math.atan2(b.dy - a.dy, b.dx - a.dx));
      turned.rgba = await turned.render();
      c.photo.dispose();
      second.add(turned);
    }
    if (second.isEmpty) return null;
    final secondPixels = [for (final c in second) c.rgba!];
    final shapes = await Isolate.run(() => _read(modelBytes, secondPixels, canonical: true, phone: phone));
    final good = [for (final s in shapes) ?s];
    if (good.isEmpty) return null;

    final mean = Float32List(points * 3);
    for (final s in good) {
      for (var i = 0; i < mean.length; i++) {
        mean[i] += s[i] / good.length;
      }
    }
    final total = (await db.faceModelStats(personId)).faces;
    await db.savePersonShape(personId, mean, facesUsed: good.length, faceCount: total);
    return mean;
  }

  /// Opens a photo (upright), no bigger than about 3000 px across. On a
  /// phone, [path] is the photo library's id: a 1600 px upright copy.
  static Future<ui.Image?> _open(String path) async {
    try {
      final Uint8List bytes;
      if (Device.desktop) {
        bytes = await File(path).readAsBytes();
      } else {
        final entity = await AssetEntity.fromId(path);
        final copy = await entity?.thumbnailDataWithSize(const ThumbnailSize(1600, 1600), quality: 92);
        if (copy == null) return null;
        bytes = copy;
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
        if (math.max(w, h) <= 3000) return ui.TargetImageSize(width: w, height: h);
        return w >= h ? const ui.TargetImageSize(width: 3000) : const ui.TargetImageSize(height: 3000);
      });
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (e) {
      debugPrint('Face shape: could not open $path: $e');
      return null;
    }
  }

  /// Runs the model on 192 x 192 RGBA crops. Returns each face's 468
  /// points (in crop pixels, or straightened when [canonical]), or null
  /// where the model didn't see a face.
  static List<Float32List?> _read(Uint8List model, List<Uint8List> crops,
      {required bool canonical, bool phone = false}) {
    if (phone) return _readTflite(model, crops, canonical: canonical);
    OrtEnv.instance.init();
    final session = LiteSession.open(model, threads: 2);
    try {
      final input = Float32List(_side * _side * 3);
      return [
        for (final rgba in crops)
          () {
            for (var i = 0, o = 0; i < _side * _side; i++) {
              input[o++] = rgba[i * 4] / 255;
              input[o++] = rgba[i * 4 + 1] / 255;
              input[o++] = rgba[i * 4 + 2] / 255;
            }
            final out = session.run(input, const [1, _side, _side, 3]);
            final score = 1 / (1 + math.exp(-out[1][0]));
            if (score < 0.6) return null;
            return canonical ? _straighten(out[0]) : Float32List.fromList(out[0]);
          }(),
      ];
    } finally {
      session.close();
      OrtEnv.instance.release();
    }
  }

  /// Phones: the same model in TensorFlow Lite.
  static List<Float32List?> _readTflite(Uint8List model, List<Uint8List> crops, {required bool canonical}) {
    final interpreter = Interpreter.fromBuffer(model, options: InterpreterOptions()..threads = 2);
    try {
      final input = Float32List(_side * _side * 3);
      return [
        for (final rgba in crops)
          () {
            for (var i = 0, o = 0; i < _side * _side; i++) {
              input[o++] = rgba[i * 4] / 255;
              input[o++] = rgba[i * 4 + 1] / 255;
              input[o++] = rgba[i * 4 + 2] / 255;
            }
            final mesh = [
              [
                [List<double>.filled(FaceShape.points * 3, 0)],
              ],
            ];
            final flag = [
              [
                [List<double>.filled(1, 0)],
              ],
            ];
            interpreter.runForMultipleInputs([input.buffer.asUint8List()], {0: mesh, 1: flag});
            final score = 1 / (1 + math.exp(-flag[0][0][0][0]));
            if (score < 0.6) return null;
            final raw = Float32List.fromList(mesh[0][0][0]);
            return canonical ? _straighten(raw) : raw;
          }(),
      ];
    } finally {
      interpreter.close();
    }
  }

  /// One face's points turned to face straight ahead (no turn, tilt or
  /// lean), centred between the eyes, eyes one unit apart, +z towards you.
  static Float32List? _straighten(Float32List raw) {
    final p = Float32List(points * 3);
    for (var i = 0; i < points; i++) {
      p[i * 3] = raw[i * 3];
      p[i * 3 + 1] = raw[i * 3 + 1];
      p[i * 3 + 2] = -raw[i * 3 + 2]; // the model's z grows away from you
    }
    void turn(int a, int b, double angle) {
      // Rotates every point in the plane of axes a and b.
      final c = math.cos(angle), s = math.sin(angle);
      for (var i = 0; i < points; i++) {
        final u = p[i * 3 + a], v = p[i * 3 + b];
        p[i * 3 + a] = u * c + v * s;
        p[i * 3 + b] = -u * s + v * c;
      }
    }

    double d(int i, int j, int axis) => p[j * 3 + axis] - p[i * 3 + axis];
    // Turn (around the vertical): the eyes level in depth.
    turn(0, 2, math.atan2(d(eyeLeft, eyeRight, 2), d(eyeLeft, eyeRight, 0)));
    // Lean (in the picture): the eyes level.
    turn(0, 1, math.atan2(d(eyeLeft, eyeRight, 1), d(eyeLeft, eyeRight, 0)));
    // Tilt (nodding): forehead straight above the chin.
    turn(1, 2, math.atan2(d(forehead, chin, 2), d(forehead, chin, 1)));
    final ex = (p[eyeLeft * 3] + p[eyeRight * 3]) / 2;
    final ey = (p[eyeLeft * 3 + 1] + p[eyeRight * 3 + 1]) / 2;
    final ez = (p[eyeLeft * 3 + 2] + p[eyeRight * 3 + 2]) / 2;
    final span = math.sqrt(math.pow(d(eyeLeft, eyeRight, 0), 2) + math.pow(d(eyeLeft, eyeRight, 1), 2) +
        math.pow(d(eyeLeft, eyeRight, 2), 2));
    if (span < 1) return null;
    for (var i = 0; i < points; i++) {
      p[i * 3] = (p[i * 3] - ex) / span;
      p[i * 3 + 1] = (p[i * 3 + 1] - ey) / span;
      p[i * 3 + 2] = (p[i * 3 + 2] - ez) / span;
    }
    return p;
  }
}

/// A square cut out of a photo around a face, turned by [angle] (radians)
/// so the eyes are level.
class _Crop {
  _Crop(this.assetId, this.photo, this.cx, this.cy, this.side, this.angle);

  final String assetId;
  final ui.Image photo;
  final double cx, cy, side, angle;
  Uint8List? rgba;

  Future<Uint8List> render() async {
    const out = FaceShape._side;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas
      ..translate(out / 2, out / 2)
      ..rotate(-angle)
      ..scale(out / side)
      ..translate(-cx, -cy);
    canvas.drawImage(photo, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.medium);
    final picture = recorder.endRecording();
    final image = await picture.toImage(out, out);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  }
}

/// Mesh lines for a face shape: the edges of a triangulation of its points
/// as seen from the front (Delaunay), as pairs of point indices. Long
/// edges across the outline are dropped.
List<int> faceShapeEdges(Float32List shape) {
  final n = FaceShape.points;
  final xs = [for (var i = 0; i < n; i++) shape[i * 3].toDouble()];
  final ys = [for (var i = 0; i < n; i++) shape[i * 3 + 1].toDouble()];
  final tris = _delaunay(xs, ys);
  final edges = <int>{};
  final lengths = <double>[];
  for (final t in tris) {
    for (final (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]) {
      lengths.add(math.sqrt(math.pow(xs[a] - xs[b], 2) + math.pow(ys[a] - ys[b], 2)));
    }
  }
  lengths.sort();
  final limit = lengths.isEmpty ? 1.0 : lengths[lengths.length ~/ 2] * 3.2;
  for (final t in tris) {
    for (final (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]) {
      final len = math.sqrt(math.pow(xs[a] - xs[b], 2) + math.pow(ys[a] - ys[b], 2));
      if (len > limit) continue;
      edges.add(a < b ? a * 1000 + b : b * 1000 + a);
    }
  }
  return [for (final e in edges) ...[e ~/ 1000, e % 1000]];
}

/// Bowyer-Watson triangulation; returns triangles as index triples.
List<List<int>> _delaunay(List<double> xs, List<double> ys) {
  final n = xs.length;
  var minX = xs.reduce(math.min), maxX = xs.reduce(math.max), minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
  final d = math.max(maxX - minX, maxY - minY) * 20;
  final mx = (minX + maxX) / 2, my = (minY + maxY) / 2;
  final px = [...xs, mx - d, mx, mx + d], py = [...ys, my - d, my + d, my - d];
  var tris = <List<int>>[[n, n + 1, n + 2]];
  bool inCircle(List<int> t, double x, double y) {
    final ax = px[t[0]] - x, ay = py[t[0]] - y;
    final bx = px[t[1]] - x, by = py[t[1]] - y;
    final cx = px[t[2]] - x, cy = py[t[2]] - y;
    final det = (ax * ax + ay * ay) * (bx * cy - cx * by) - (bx * bx + by * by) * (ax * cy - cx * ay) +
        (cx * cx + cy * cy) * (ax * by - bx * ay);
    final orient = (px[t[1]] - px[t[0]]) * (py[t[2]] - py[t[0]]) - (py[t[1]] - py[t[0]]) * (px[t[2]] - px[t[0]]);
    return orient > 0 ? det > 0 : det < 0;
  }

  for (var i = 0; i < n; i++) {
    final x = px[i], y = py[i];
    final bad = <List<int>>[], keep = <List<int>>[];
    for (final t in tris) {
      (inCircle(t, x, y) ? bad : keep).add(t);
    }
    final count = <int, int>{};
    for (final t in bad) {
      for (final (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])]) {
        final key = a < b ? a * 1000 + b : b * 1000 + a;
        count[key] = (count[key] ?? 0) + 1;
      }
    }
    for (final e in count.entries) {
      if (e.value == 1) keep.add([e.key ~/ 1000, e.key % 1000, i]);
    }
    tris = keep;
  }
  return [for (final t in tris) if (t.every((v) => v < n)) t];
}
