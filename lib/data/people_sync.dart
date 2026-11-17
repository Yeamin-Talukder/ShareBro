import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'db.dart' show SyncPersonRow;

/// Swapping who's who between your own devices (phone ↔ laptop, phone ↔
/// phone): named people and fingerprints of their faces only. Never a
/// photo, a file name, a folder, a date or a place.
///
/// A fingerprint is 512 numbers describing a face. It can't be turned back
/// into a picture, but it does recognise the person, so it only goes to a
/// device you pick, after that device accepts.

const peopleSyncVersion = 1;

/// One named person as it travels between devices.
class SyncPerson {
  SyncPerson({
    required this.syncId,
    required this.name,
    this.nickname,
    this.gender,
    this.thumb,
    required this.embeddings,
  });

  factory SyncPerson.fromRow(SyncPersonRow r) => SyncPerson(
        syncId: r.syncId,
        name: r.name,
        nickname: r.nickname,
        gender: r.gender,
        thumb: r.thumb,
        embeddings: r.embeddings,
      );

  /// The same person on every device (given on their first sync).
  final String syncId;
  final String name;
  final String? nickname;

  /// Set by hand on the sending device ('m', 'f'), if at all.
  final String? gender;

  /// A small face crop (JPEG), to show who this is before accepting.
  final Uint8List? thumb;
  final List<Float32List> embeddings;

  Map<String, dynamic> toJson() => {
        'id': syncId,
        'name': name,
        if (nickname != null) 'nickname': nickname,
        if (gender != null) 'gender': gender,
        if (thumb != null) 'thumb': base64Encode(thumb!),
        'faces': [for (final e in embeddings) base64Encode(e.buffer.asUint8List(e.offsetInBytes, e.lengthInBytes))],
      };

  /// Null if the entry is malformed or its fingerprints aren't [dim] long.
  static SyncPerson? fromJson(Object? j, {required int dim}) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], faces = j['faces'];
    if (id is! String || id.isEmpty || id.length > 64 || name is! String || name.trim().isEmpty || faces is! List) {
      return null;
    }
    final embeddings = <Float32List>[];
    for (final f in faces.take(64)) {
      if (f is! String) continue;
      try {
        final bytes = base64Decode(f);
        if (bytes.length != dim * 4) continue;
        final v = Float32List.view(Uint8List.fromList(bytes).buffer);
        if (v.any((x) => x.isNaN || x.isInfinite)) continue;
        embeddings.add(v);
      } catch (_) {}
    }
    if (embeddings.isEmpty) return null;
    Uint8List? thumb;
    final t = j['thumb'];
    if (t is String && t.length < 200000) {
      try {
        thumb = base64Decode(t);
      } catch (_) {}
    }
    String? text(Object? v, int max) => v is String && v.trim().isNotEmpty ? v.trim().substring(0, math.min(v.trim().length, max)) : null;
    final gender = j['gender'];
    return SyncPerson(
      syncId: id,
      name: text(name, 80)!,
      nickname: text(j['nickname'], 80),
      gender: gender == 'm' || gender == 'f' ? gender as String : null,
      thumb: thumb,
      embeddings: embeddings,
    );
  }
}

/// Everyone one device knows, from that device.
class PeoplePackage {
  PeoplePackage({required this.from, required this.model, required this.people});

  /// The device's name ("Mahmud's laptop").
  final String from;

  /// The face model that made the fingerprints; both devices must use the
  /// same one (fingerprints from different models don't compare).
  final String model;
  final List<SyncPerson> people;

  Map<String, dynamic> toJson() => {
        'v': peopleSyncVersion,
        'from': from,
        'model': model,
        'dim': people.isEmpty ? 512 : people.first.embeddings.first.length,
        'people': [for (final p in people) p.toJson()],
      };

  /// Null if it isn't a people package this version understands.
  static PeoplePackage? fromJson(Object? j) {
    if (j is! Map || j['v'] != peopleSyncVersion) return null;
    final model = j['model'], from = j['from'], dim = j['dim'], people = j['people'];
    if (model is! String || dim is! int || dim <= 0 || dim > 4096 || people is! List) return null;
    return PeoplePackage(
      from: from is String && from.trim().isNotEmpty ? from.trim() : 'Another device',
      model: model,
      people: [
        for (final p in people.take(2000)) ?SyncPerson.fromJson(p, dim: dim),
      ],
    );
  }
}

/// Where an incoming person lands on this device.
class PersonMatch {
  const PersonMatch(this.localId, {this.bySyncId = false, this.similarity = 0});

  /// The person already here, or null for someone new.
  final int? localId;

  /// Matched as the same synced person (not just a similar face).
  final bool bySyncId;
  final double similarity;
}

/// For each incoming person: the person already on this device who is the
/// same (synced before, or their faces' average is at least [threshold]
/// alike), or null for someone new.
List<PersonMatch> matchPeople(
  List<SyncPerson> incoming,
  Map<int, ({String? name, String? syncId, List<Float32List> embeddings})> local,
  double threshold,
) {
  final centroids = {for (final e in local.entries) e.key: _centroid(e.value.embeddings)};
  final bySync = {
    for (final e in local.entries)
      if (e.value.syncId != null) e.value.syncId!: e.key,
  };
  return [
    for (final p in incoming)
      () {
        final synced = bySync[p.syncId];
        if (synced != null) return PersonMatch(synced, bySyncId: true, similarity: 1);
        final c = _centroid(p.embeddings);
        int? best;
        var bestSim = threshold;
        for (final e in centroids.entries) {
          final s = _dot(c, e.value);
          if (s >= bestSim) {
            bestSim = s;
            best = e.key;
          }
        }
        return PersonMatch(best, similarity: best == null ? 0 : bestSim);
      }(),
  ];
}

/// The faces' average direction, unit length.
Float32List _centroid(List<Float32List> vs) {
  final dim = vs.first.length;
  final sum = Float32List(dim);
  for (final v in vs) {
    if (v.length != dim) continue;
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = n == 0 ? 1 : math.sqrt(n);
    for (var i = 0; i < dim; i++) {
      sum[i] += v[i] / n;
    }
  }
  var n = 0.0;
  for (final x in sum) {
    n += x * x;
  }
  n = n == 0 ? 1 : math.sqrt(n);
  for (var i = 0; i < dim; i++) {
    sum[i] /= n;
  }
  return sum;
}

double _dot(Float32List a, Float32List b) {
  if (a.length != b.length) return -1;
  var d = 0.0;
  for (var i = 0; i < a.length; i++) {
    d += a[i] * b[i];
  }
  return d;
}

/// Two devices call the same person by different names.
class NameConflict {
  NameConflict({required this.localId, required this.localName, required this.theirName, this.thumb});

  final int localId;
  final String localName;
  final String theirName;
  final Uint8List? thumb;
}

/// What a sync did on this device.
class PeopleSyncResult {
  PeopleSyncResult({
    this.from = '',
    this.added = 0,
    this.matched = 0,
    this.named = 0,
    this.conflicts = const [],
    this.wrongModel = false,
  });

  /// The other device's name.
  final String from;

  /// People new to this device (recognised from now on).
  final int added;

  /// People this device already had (their faces from the other device
  /// were added, so they're recognised better).
  final int matched;

  /// People this device had without a name, named from the other device.
  final int named;
  final List<NameConflict> conflicts;

  /// The other device uses a different face model: nothing was taken.
  final bool wrongModel;

  int get total => added + matched;
}
