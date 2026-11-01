import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/clustering.dart';

Float32List unit(int length, int seed) {
  final r = math.Random(seed);
  final v = Float32List.fromList([for (var i = 0; i < length; i++) r.nextDouble() - 0.5]);
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  for (var i = 0; i < length; i++) {
    v[i] /= n;
  }
  return v;
}

void main() {
  test('fingerprints from the old and new face models never match (or crash)', () {
    // A friend's phone on an older version sends 128-number fingerprints;
    // this one makes 512-number ones.
    final old = unit(128, 1), fresh = unit(512, 2);
    expect(suggestMatches(SuggestInput({1: [old]}, {7: fresh}, 0.0)), isEmpty);
    expect(suggestMatches(SuggestInput({1: [fresh]}, {7: old}, 0.0)), isEmpty);
  });

  test('the same new-model fingerprint still matches itself', () {
    final v = unit(512, 3);
    final m = suggestMatches(SuggestInput({1: [v]}, {7: v}, 0.3));
    expect(m.single.personId, 1);
    expect(m.single.similarity, closeTo(1, 1e-5));
  });

  test('grouping thresholds suit the new model', () {
    final t = GroupingThresholds.fromStrictness(GroupingThresholds.defaultStrictness);
    expect(t.assign, closeTo(0.38, 1e-9));
    expect(GroupingThresholds.fromStrictness(0).assign, closeTo(0.28, 1e-9));
    expect(GroupingThresholds.fromStrictness(1).assign, closeTo(0.48, 1e-9));
  });
}
