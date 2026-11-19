import 'dart:math' as math;
import 'dart:typed_data';

/// InsightFace's SCRFD face detector (det_10g, from the buffalo_l pack),
/// used on desktop where ML Kit isn't available. This file is the pure
/// maths around the model: preparing its input and reading its output. The
/// model itself runs in ONNX Runtime (see the desktop face engine).
///
/// The model takes a 640x640 picture and answers, for three grid sizes
/// (strides 8, 16 and 32, two anchors per cell), a face score, a box and
/// five landmarks (eyes, nose, mouth corners) as distances from the cell.
const scrfdInput = 640;
const _strides = [8, 16, 32];
const _anchorsPerCell = 2;

/// Faces less certain than this are dropped (InsightFace's default).
const scrfdMinScore = 0.5;

/// Overlapping boxes above this IoU count as the same face.
const _nmsOverlap = 0.4;

/// One face SCRFD found, in the original photo's pixels.
class ScrfdFace {
  ScrfdFace(this.score, this.left, this.top, this.right, this.bottom, this.points);

  final double score, left, top, right, bottom;

  /// Five landmarks: the eye on the image left, the eye on the image right,
  /// nose tip, mouth corner on the left, mouth corner on the right.
  final List<(double, double)> points;

  double get width => right - left;
  double get height => bottom - top;

  /// A rough left-right head turn in degrees from where the nose sits
  /// between the eyes: 0 facing the camera, about ±50 at a three-quarter
  /// profile. Not as precise as ML Kit's, but enough to skip side views.
  double get yaw {
    final lx = points[0].$1, rx = points[1].$1, nx = points[2].$1;
    final half = (rx - lx).abs() / 2;
    if (half < 1e-3) return 90;
    final off = (nx - (lx + rx) / 2) / half;
    return (off.clamp(-2.0, 2.0) * 45).toDouble();
  }
}

/// How a photo was fitted into the square model input: scaled by [scale]
/// and placed in the top-left corner, the rest left black.
class Letterbox {
  Letterbox(this.tensor, this.scale);

  /// 1x3x640x640 (or 1x640x640x3 with `channelsLast`), RGB,
  /// (v - 127.5) / 128, as SCRFD was trained.
  final Float32List tensor;
  final double scale;
}

/// Fits RGBA [pixels] (w x h) into the model's square input, keeping the
/// aspect ratio (bilinear resize). [channelsLast] for TensorFlow Lite's
/// pixel-by-pixel layout (the phone's copy of the model).
Letterbox scrfdLetterbox(Uint8List pixels, int w, int h, {bool channelsLast = false}) {
  final scale = math.min(scrfdInput / w, scrfdInput / h);
  final nw = math.max(1, (w * scale).round()), nh = math.max(1, (h * scale).round());
  const plane = scrfdInput * scrfdInput;
  final t = Float32List(3 * plane);
  // The black padding is (0 - 127.5) / 128.
  t.fillRange(0, t.length, -127.5 / 128);
  final sx = w / nw, sy = h / nh;
  for (var y = 0; y < nh; y++) {
    final fy = math.min((y + 0.5) * sy - 0.5, h - 1.0).clamp(0.0, h - 1.0);
    final y0 = fy.floor(), y1 = math.min(y0 + 1, h - 1);
    final dy = fy - y0;
    for (var x = 0; x < nw; x++) {
      final fx = math.min((x + 0.5) * sx - 0.5, w - 1.0).clamp(0.0, w - 1.0);
      final x0 = fx.floor(), x1 = math.min(x0 + 1, w - 1);
      final dx = fx - x0;
      final i00 = (y0 * w + x0) * 4, i10 = (y0 * w + x1) * 4;
      final i01 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4;
      final o = y * scrfdInput + x;
      for (var c = 0; c < 3; c++) {
        final top = pixels[i00 + c] + (pixels[i10 + c] - pixels[i00 + c]) * dx;
        final bottom = pixels[i01 + c] + (pixels[i11 + c] - pixels[i01 + c]) * dx;
        t[channelsLast ? o * 3 + c : c * plane + o] = (top + (bottom - top) * dy - 127.5) / 128;
      }
    }
  }
  return Letterbox(t, scale);
}

/// Reads SCRFD's nine outputs ([outputs] in model order: scores for strides
/// 8/16/32, then boxes, then landmarks, each flattened) into faces in the
/// photo's pixels, most certain first, with overlaps removed.
List<ScrfdFace> scrfdDecode(List<Float32List> outputs, double scale, {double minScore = scrfdMinScore}) {
  final found = <ScrfdFace>[];
  for (var s = 0; s < _strides.length; s++) {
    final stride = _strides[s];
    final scores = outputs[s], boxes = outputs[s + 3], kps = outputs[s + 6];
    final cells = scrfdInput ~/ stride;
    for (var k = 0; k < scores.length; k++) {
      final score = scores[k];
      if (score < minScore) continue;
      final cell = k ~/ _anchorsPerCell;
      final cx = (cell % cells) * stride.toDouble(), cy = (cell ~/ cells) * stride.toDouble();
      final b = k * 4, p = k * 10;
      found.add(ScrfdFace(
        score,
        (cx - boxes[b] * stride) / scale,
        (cy - boxes[b + 1] * stride) / scale,
        (cx + boxes[b + 2] * stride) / scale,
        (cy + boxes[b + 3] * stride) / scale,
        [
          for (var j = 0; j < 5; j++)
            ((cx + kps[p + 2 * j] * stride) / scale, (cy + kps[p + 2 * j + 1] * stride) / scale),
        ],
      ));
    }
  }
  found.sort((a, b) => b.score.compareTo(a.score));
  final kept = <ScrfdFace>[];
  for (final f in found) {
    if (kept.every((g) => _overlap(f, g) <= _nmsOverlap)) kept.add(f);
  }
  return kept;
}

double _overlap(ScrfdFace a, ScrfdFace b) {
  final iw = math.max(0.0, math.min(a.right, b.right) - math.max(a.left, b.left));
  final ih = math.max(0.0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top));
  final inter = iw * ih;
  final union = a.width * a.height + b.width * b.height - inter;
  return union <= 0 ? 0 : inter / union;
}
