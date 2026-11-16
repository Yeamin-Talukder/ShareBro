import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/scrfd.dart';

/// The fixture is SCRFD-10G's real output for a hiking photo with five
/// people (900x600), made with InsightFace's reference decoding in Python
/// (only rows that could be faces are kept, to stay small).
void main() {
  final meta = jsonDecode(File('test/fixtures/scrfd_expected.json').readAsStringSync()) as Map<String, dynamic>;
  final raw = gzip.decode(File('test/fixtures/scrfd_outputs.bin.gz').readAsBytesSync());
  final floats = Uint8List.fromList(raw).buffer.asFloat32List();
  final outputs = <Float32List>[];
  var o = 0;
  for (final s in (meta['shapes'] as List).cast<List<dynamic>>()) {
    final n = s.fold<int>(1, (a, b) => a * (b as int));
    outputs.add(Float32List.sublistView(floats, o, o + n));
    o += n;
  }
  final w = meta['width'] as int, h = meta['height'] as int;
  final scale = (640 / w) < (640 / h) ? 640 / w : 640 / h;

  test('decodes the same faces as InsightFace', () {
    final faces = scrfdDecode(outputs, scale);
    final expected = (meta['faces'] as List).cast<Map<String, dynamic>>();
    expect(faces, hasLength(expected.length));
    for (final (i, e) in expected.indexed) {
      final box = (e['box'] as List).cast<num>();
      final f = faces[i];
      expect(f.score, closeTo(e['score'] as num, 1e-4));
      expect([f.left, f.top, f.right, f.bottom], [for (final v in box) closeTo(v, 0.01)]);
      final kps = (e['kps'] as List).cast<List<dynamic>>();
      for (var j = 0; j < 5; j++) {
        expect(f.points[j].$1, closeTo(kps[j][0] as num, 0.01));
        expect(f.points[j].$2, closeTo(kps[j][1] as num, 0.01));
      }
    }
  });

  test('profile faces read as turned', () {
    final faces = scrfdDecode(outputs, scale);
    // The two most frontal people sit near 0; the ones looking sideways
    // (eyes almost on top of each other) read as strongly turned.
    final yaws = [for (final f in faces) f.yaw.abs()]..sort();
    expect(yaws.first, lessThan(30));
    expect(yaws.last, greaterThan(50));
  });

  test('letterbox keeps the aspect ratio and pads with black', () {
    final pixels = Uint8List(200 * 100 * 4)..fillRange(0, 200 * 100 * 4, 255);
    final lb = scrfdLetterbox(pixels, 200, 100);
    expect(lb.scale, 640 / 200);
    const plane = 640 * 640;
    expect(lb.tensor.length, 3 * plane);
    // Inside the photo (white) and in the padding below it (black).
    expect(lb.tensor[10 * 640 + 10], closeTo((255 - 127.5) / 128, 1e-6));
    expect(lb.tensor[2 * plane + 600 * 640 + 10], closeTo(-127.5 / 128, 1e-6));
  });
}
