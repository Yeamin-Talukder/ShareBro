import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/data/duplicates.dart';
import 'package:photo_organizer/face/clustering.dart';
import 'package:photo_organizer/face/tags.dart';

Float32List _unit(List<double> v) {
  final n = math.sqrt(v.fold(0.0, (s, x) => s + x * x));
  return Float32List.fromList([for (final x in v) x / n]);
}

List<double> _axis(int i, [int dim = 16]) => List.generate(dim, (k) => k == i ? 1.0 : 0.0);

void main() {
  test('difference hash and hamming distance', () {
    final ramp = [for (var y = 0; y < 8; y++) for (var x = 0; x < 9; x++) x * 10];
    expect(differenceHash(ramp), -1); // every pixel brighter than its left: all 64 bits set
    final flat = List.filled(72, 50);
    expect(differenceHash(flat), 0);
    expect(hammingDistance(0, -1), 64);
    expect(hammingDistance(0x0F, 0x0E), 1);
  });

  test('bursts become one duplicate set and the best shot is kept', () {
    PhotoFingerprint f(String id, int hash, int sec, double q) =>
        PhotoFingerprint(id, hash, sec * 1000, q, false);
    final sets = findDuplicates([
      f('a', 0x00FF, 0, 0.4),
      f('b', 0x00FE, 3, 0.9), // 1 bit off, 3 s later
      f('c', 0x00FC, 6, 0.6),
      f('d', 0x00FF, 600, 0.5), // same look but 10 minutes later: new moment
      f('e', -1, 601, 0.5), // very different picture
    ]);
    expect(sets, hasLength(1));
    expect(sets.first.photos.map((p) => p.assetId), ['a', 'b', 'c']);
    expect(sets.first.best, 'b');
    expect(sets.first.extras, ['a', 'c']);
  });

  test('a person with two looks still matches both', () {
    // Faces 1-4 are person 7 in two different looks (e.g. glasses / no glasses).
    final look1 = _unit(_axis(0)), look2 = _unit(_axis(1));
    final newFace = _unit([0.05, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final result = groupFaces(GroupingInput(
      [1, 2, 3, 4, 5],
      [look1, look1, look2, look2, newFace],
      [7, 7, 7, 7, null],
      [true, true, true, true, false],
      const GroupingThresholds(),
    ));
    // One average of both looks would be ~0.7 similar; the closest look is ~1.
    expect(result.assignToExisting, {5: 7});
  });

  test('look-alike people are suggested for merging, dismissed pairs are not', () {
    final a = _unit([1, 0.75, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final b = _unit([0.75, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final c = _unit(_axis(5));
    final people = {1: [a], 2: [b], 3: [c]};
    final hints = suggestMerges(MergeInput(people, {}, 0.8, 0.99));
    expect(hints.map((h) => (h.a, h.b)), [(1, 2)]);
    expect(suggestMerges(MergeInput(people, {(1, 2)}, 0.8, 0.99)), isEmpty);
  });

  test('eyes closed, looking away and smiles become tags', () {
    final t = tagsFor(PhotoFacts(
      faceCount: 3,
      maxFaceArea: 0.01,
      minFaceSharpness: 120,
      width: 4000,
      height: 3000,
      folder: 'DCIM/Camera/',
      title: 'PXL.jpg',
      hasLocation: false,
      labels: const [],
      minEyesOpen: 0.1,
      maxSmile: 0.9,
      maxYaw: 40,
    ));
    expect(t, containsAll(['eyes_closed', 'looking_away', 'smiling', 'group']));
    expect(photoQuality(faceCount: 0), 0.5);
    expect(
      photoQuality(faceCount: 1, avgSharpness: 200, minEyesOpen: 1, maxSmile: 1),
      greaterThan(photoQuality(faceCount: 1, avgSharpness: 200, minEyesOpen: 0.1, maxSmile: 0)),
    );
  });
}
