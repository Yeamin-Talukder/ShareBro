import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/people_sync.dart';

/// A unit-length fingerprint near [base] (noise keeps it the same person).
Float32List face(int base, {double noise = 0.15, int seed = 0, int dim = 512}) {
  final r = math.Random(base * 1000 + seed);
  final b = math.Random(base);
  final v = Float32List(dim);
  var n = 0.0;
  for (var i = 0; i < dim; i++) {
    v[i] = (b.nextDouble() - 0.5) + noise * (r.nextDouble() - 0.5);
    n += v[i] * v[i];
  }
  n = math.sqrt(n);
  for (var i = 0; i < dim; i++) {
    v[i] /= n;
  }
  return v;
}

SyncPerson person(String id, String name, int who, {int faces = 5}) => SyncPerson(
      syncId: id,
      name: name,
      thumb: Uint8List.fromList([1, 2, 3]),
      embeddings: [for (var k = 0; k < faces; k++) face(who, seed: k)],
    );

void main() {
  test('a package survives the trip between devices', () {
    final sent = PeoplePackage(from: "Mahmud's laptop", model: 'w600k_mbf', people: [
      person('a1', 'Ruby', 1),
      SyncPerson(syncId: 'b2', name: 'Leo', nickname: 'Lee', gender: 'm', embeddings: [face(2)]),
    ]);
    // Through JSON, as over the network.
    final got = PeoplePackage.fromJson(jsonDecode(jsonEncode(sent.toJson())))!;
    expect(got.from, "Mahmud's laptop");
    expect(got.model, 'w600k_mbf');
    expect(got.people.map((p) => p.name), ['Ruby', 'Leo']);
    expect(got.people[1].nickname, 'Lee');
    expect(got.people[1].gender, 'm');
    expect(got.people[0].thumb, [1, 2, 3]);
    expect(got.people[0].embeddings.length, 5);
    expect(got.people[0].embeddings[3], sent.people[0].embeddings[3]);
  });

  test('broken or foreign packages are refused, bad entries skipped', () {
    expect(PeoplePackage.fromJson(null), isNull);
    expect(PeoplePackage.fromJson({'v': 99, 'model': 'x', 'dim': 512, 'people': []}), isNull);
    final got = PeoplePackage.fromJson({
      'v': peopleSyncVersion,
      'from': 'Phone',
      'model': 'w600k_mbf',
      'dim': 512,
      'people': [
        {'id': 'ok', 'name': 'Maya', 'faces': [base64Encode(face(3).buffer.asUint8List())]},
        {'id': 'short', 'name': 'Nia', 'faces': [base64Encode(Float32List(10).buffer.asUint8List())]},
        {'id': '', 'name': 'No id', 'faces': [base64Encode(face(4).buffer.asUint8List())]},
        {'id': 'noname', 'name': '  ', 'faces': [base64Encode(face(5).buffer.asUint8List())]},
        'not a person',
        {'id': 'g', 'name': 'Zara', 'gender': 'x', 'faces': [base64Encode(face(6).buffer.asUint8List())]},
      ],
    })!;
    expect(got.people.map((p) => p.name), ['Maya', 'Zara']);
    expect(got.people[1].gender, isNull);
  });

  test('the same person is found by sync id, then by face; strangers are new', () {
    final local = {
      10: (name: 'Ruby', syncId: 'a1', embeddings: [face(1, seed: 50), face(1, seed: 51)]),
      20: (name: null, syncId: null, embeddings: [face(2, seed: 60)]),
      30: (name: 'Andre', syncId: null, embeddings: [face(9, seed: 70)]),
    };
    final incoming = [
      person('a1', 'Ruby', 7), // synced before: matched by id even if the faces differ
      person('zz', 'Leo', 2), // never synced, but the same face as local 20
      person('qq', 'Maya', 3), // nobody here
    ];
    final m = matchPeople(incoming, local, 0.48);
    expect(m[0].localId, 10);
    expect(m[0].bySyncId, isTrue);
    expect(m[1].localId, 20);
    expect(m[1].bySyncId, isFalse);
    expect(m[1].similarity, greaterThan(0.48));
    expect(m[2].localId, isNull);
  });
}
