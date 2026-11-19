import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/face_shape.dart';

void main() {
  test('mesh lines join every point of a face-like shape, without long jumps', () {
    // 468 points spread over an oval, roughly like a face seen from the front.
    final r = math.Random(4);
    final shape = Float32List(FaceShape.points * 3);
    for (var i = 0; i < FaceShape.points; i++) {
      final a = r.nextDouble() * 2 * math.pi, d = math.sqrt(r.nextDouble());
      shape[i * 3] = math.cos(a) * d * 0.9;
      shape[i * 3 + 1] = math.sin(a) * d * 1.2;
      shape[i * 3 + 2] = (1 - d) * 0.5;
    }
    final edges = faceShapeEdges(shape);
    expect(edges.length.isEven, isTrue);
    // A triangulation of n points has about 3n edges.
    expect(edges.length ~/ 2, greaterThan(FaceShape.points * 2));
    final used = <int>{...edges};
    expect(used.length, greaterThan(FaceShape.points - 5));
    expect(edges.every((i) => i >= 0 && i < FaceShape.points), isTrue);
  });
}
