// Renders the app icon (same geometry as
// android/app/src/main/res/drawable/ic_launcher_*.xml) to PNGs:
// legacy launcher mipmaps and a 1024 px preview.
//
//   dart run tool/make_icon.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

// ---- geometry, in the 108-unit adaptive icon canvas ----
const _stops = [
  (0.0, (0xFF, 0x8A, 0x5C)),
  (0.5, (0xE8, 0x45, 0x7A)),
  (1.0, (0x6E, 0x5B, 0xFF)),
];
const _gradFrom = (18.0, 14.0), _gradTo = (92.0, 96.0);
/// The foreground is drawn on a 100-unit grid, scaled by [_scale] about its
/// centre and moved to the canvas centre (54, 54) — like the vector's `group`.
const _scale = 0.74;

/// Friends and trail dots as (x, y, radius, alpha), in the 100-unit grid.
const _dots = [
  (22.0, 30.0, 6.0, 0.5),
  (36.0, 24.0, 6.0, 0.5),
  (29.0, 40.0, 6.5, 1.0),
  (44.0, 72.0, 2.0, 0.75),
  (36.0, 77.0, 1.8, 0.55),
  (28.0, 79.0, 1.6, 0.35),
];

/// The paper plane: top wing, then the folded lower wing, as (triangle, alpha).
const _wings = [
  (((30.0, 58.0), (80.0, 34.0), (55.0, 62.0)), 1.0),
  (((55.0, 62.0), (80.0, 34.0), (66.0, 74.0)), 0.72),
];

bool _inTriangle(double x, double y, ((double, double), (double, double), (double, double)) t) {
  final ((ax, ay), (bx, by), (cx, cy)) = t;
  double side(double px, double py, double qx, double qy) => (x - qx) * (py - qy) - (px - qx) * (y - qy);
  final d1 = side(ax, ay, bx, by), d2 = side(bx, by, cx, cy), d3 = side(cx, cy, ax, ay);
  final neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(neg && pos);
}

(double, double, double) _background(double x, double y) {
  final dx = _gradTo.$1 - _gradFrom.$1, dy = _gradTo.$2 - _gradFrom.$2;
  final t = (((x - _gradFrom.$1) * dx + (y - _gradFrom.$2) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
  for (var i = 0; i < _stops.length - 1; i++) {
    final (t0, c0) = _stops[i];
    final (t1, c1) = _stops[i + 1];
    if (t <= t1) {
      final k = (t - t0) / (t1 - t0);
      return (c0.$1 + (c1.$1 - c0.$1) * k, c0.$2 + (c1.$2 - c0.$2) * k, c0.$3 + (c1.$3 - c0.$3) * k);
    }
  }
  final c = _stops.last.$2;
  return (c.$1.toDouble(), c.$2.toDouble(), c.$3.toDouble());
}

/// Colour of the icon at canvas point (x, y), alpha-composited.
(double, double, double) _sample(double x, double y) {
  var (r, g, b) = _background(x, y);
  // Back to the 100-unit design grid.
  final u = 50 + (x - 54) / _scale, v = 50 + (y - 54) / _scale;
  void over(double a) {
    r += (255 - r) * a;
    g += (255 - g) * a;
    b += (255 - b) * a;
  }

  for (final (cx, cy, rad, a) in _dots) {
    if ((u - cx) * (u - cx) + (v - cy) * (v - cy) <= rad * rad) over(a);
  }
  // The lower wing sits beside the top one, so only one applies per point.
  for (final (t, a) in _wings) {
    if (_inTriangle(u, v, t)) {
      over(a);
      break;
    }
  }
  return (r, g, b);
}

/// Renders the canvas square [from..to] to a [size] px image with 4x4
/// supersampling. [radius] (0..0.5 of size) rounds the corners.
img.Image render(int size, {double from = 18, double to = 90, double radius = 0.22}) {
  final out = img.Image(width: size, height: size, numChannels: 4);
  const ss = 4;
  final scale = (to - from) / size;
  final r = radius * size;
  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var sr = 0.0, sg = 0.0, sb = 0.0, inside = 0;
      for (var j = 0; j < ss; j++) {
        for (var i = 0; i < ss; i++) {
          final fx = px + (i + 0.5) / ss, fy = py + (j + 0.5) / ss;
          // Rounded-square mask.
          final qx = math.max(0.0, (fx - size / 2).abs() - (size / 2 - r));
          final qy = math.max(0.0, (fy - size / 2).abs() - (size / 2 - r));
          if (qx * qx + qy * qy > r * r) continue;
          final (cr, cg, cb) = _sample(from + fx * scale, from + fy * scale);
          sr += cr;
          sg += cg;
          sb += cb;
          inside++;
        }
      }
      if (inside == 0) {
        out.setPixelRgba(px, py, 0, 0, 0, 0);
      } else {
        out.setPixelRgba(px, py, (sr / inside).round(), (sg / inside).round(),
            (sb / inside).round(), (255 * inside / (ss * ss)).round());
      }
    }
  }
  return out;
}

void main() {
  const res = 'android/app/src/main/res';
  const sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  for (final e in sizes.entries) {
    File('$res/mipmap-${e.key}/ic_launcher.png').writeAsBytesSync(img.encodePng(render(e.value)));
    stdout.writeln('mipmap-${e.key}: ${e.value} px');
  }
  Directory('assets/icon').createSync(recursive: true);
  File('assets/icon/app_icon_1024.png').writeAsBytesSync(img.encodePng(render(1024)));
  // Full-bleed square for app stores (they apply their own mask).
  File('assets/icon/app_icon_store_512.png')
      .writeAsBytesSync(img.encodePng(render(512, from: 14, to: 94, radius: 0)));
  stdout.writeln('assets/icon/app_icon_1024.png, app_icon_store_512.png');
}
