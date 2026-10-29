import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/clustering.dart';

/// A unit vector near [base], nudged by a little random noise.
Float32List _near(List<double> base, math.Random r, [double noise = 0.15]) {
  final v = [for (final x in base) x + (r.nextDouble() - 0.5) * noise];
  final n = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
  return Float32List.fromList([for (final x in v) x / n]);
}

List<double> _axis(int i, int dim) => List.generate(dim, (k) => k == i ? 1 : 0);

void main() {
  const dim = 16;
  final r = math.Random(1);

  test('groups faces of the same person together', () {
    final emb = [
      for (var i = 0; i < 5; i++) _near(_axis(0, dim), r),
      for (var i = 0; i < 4; i++) _near(_axis(1, dim), r),
      _near(_axis(2, dim), r), // a stranger seen once
    ];
    final ids = List.generate(emb.length, (i) => i + 1);
    final result = groupFaces(GroupingInput(ids, emb, List.filled(emb.length, null),
        List.filled(emb.length, false), const GroupingThresholds()));

    final groups = [for (final g in result.newGroups) (g.toList()..sort()).join(',')];
    expect(groups, unorderedEquals(['1,2,3,4,5', '6,7,8,9']));
  });

  test('new faces join an existing person and locked faces stay put', () {
    final emb = [
      _near(_axis(0, dim), r),
      _near(_axis(0, dim), r),
      _near(_axis(0, dim), r),
      _near(_axis(0, dim), r),
    ];
    final result = groupFaces(GroupingInput([1, 2, 3, 4], emb, [7, null, null, null],
        [true, false, false, true], const GroupingThresholds()));

    expect(result.assignToExisting, {2: 7, 3: 7});
    expect(result.newGroups, isEmpty);
  });
}
