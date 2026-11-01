import 'dart:isolate';
import 'dart:math' as math;

import '../face/tags.dart' show labelPrefix;
import 'db.dart';
import 'trip_days.dart' show vagueLabels;

/// Photos taken within this distance of a place's middle belong to it.
const placeRadiusMeters = 400.0;

/// A label needs at least this share of a place's photos to name it.
const _nameShare = 0.25;

/// One spot photos were taken at: its middle, its photos in time order and
/// what most of them show ("Beach").
class Place {
  Place(this.lat, this.lng, this.photos, this.times);

  final double lat, lng;

  /// Asset ids, oldest first.
  final List<String> photos;
  final List<DateTime> times;

  /// What stands out in its photos; null when nothing does.
  String? scene;

  /// Order of the first visit, from 1.
  int number = 0;

  DateTime get first => times.first;
  DateTime get last => times.last;
  String get cover => photos[photos.length ~/ 2];
  String get name => scene ?? 'Place $number';
}

/// Metres between two points on the earth (haversine).
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// Flat-earth distance: fast, and within a hair of [distanceMeters] at
/// the few hundred metres grouping cares about. [cosLat] is cos(lat1).
double _nearMeters(double lat1, double lng1, double lat2, double lng2, double cosLat) {
  const perDegree = 111195.0;
  final dy = (lat2 - lat1) * perDegree, dx = (lng2 - lng1) * perDegree * cosLat;
  return math.sqrt(dx * dx + dy * dy);
}

/// Groups located photos (oldest first) into places: each photo joins the
/// nearest place within [placeRadiusMeters], or starts a new one. Places
/// come back in the order they were first visited.
List<Place> groupPlaces(List<({String id, DateTime at, double lat, double lng})> shots) {
  final sums = <({List<String> ids, List<DateTime> at, double lat, double lng})>[];
  for (final s in shots) {
    var best = -1;
    var bestD = placeRadiusMeters;
    final cosLat = math.cos(s.lat * math.pi / 180);
    for (var i = 0; i < sums.length; i++) {
      final p = sums[i];
      final n = p.ids.length;
      final d = _nearMeters(p.lat / n, p.lng / n, s.lat, s.lng, cosLat);
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) {
      sums.add((ids: [s.id], at: [s.at], lat: s.lat, lng: s.lng));
    } else {
      final p = sums[best];
      p.ids.add(s.id);
      p.at.add(s.at);
      sums[best] = (ids: p.ids, at: p.at, lat: p.lat + s.lat, lng: p.lng + s.lng);
    }
  }
  final places = [for (final p in sums) Place(p.lat / p.ids.length, p.lng / p.ids.length, p.ids, p.at)];
  for (final (i, p) in places.indexed) {
    p.number = i + 1;
  }
  return places;
}

/// Names each place after the scene most of its photos share. Two places
/// with the same scene become "Beach" and "Beach 2".
void namePlaces(List<Place> places, Map<String, Set<String>> tags) {
  final used = <String, int>{};
  for (final p in places) {
    final n = <String, int>{};
    for (final id in p.photos) {
      for (final t in tags[id] ?? const <String>{}) {
        if (!t.startsWith(labelPrefix)) continue;
        final name = t.substring(labelPrefix.length);
        if (!vagueLabels.contains(name)) n[name] = (n[name] ?? 0) + 1;
      }
    }
    String? best;
    var most = 0;
    n.forEach((name, count) {
      if (count > most && count >= 2 && count / p.photos.length >= _nameShare) {
        most = count;
        best = name;
      }
    });
    if (best == null) continue;
    final seen = (used[best!] ?? 0) + 1;
    used[best!] = seen;
    p.scene = seen == 1 ? best : '$best $seen';
  }
}

/// The last places worked out, per trip and dates (null: all of them),
/// and the library revision they were worked out at.
final _cache = <(int?, DaySpan?), (int, List<Place>)>{};

/// Places already worked out for [tripId] / [dates] at [revision], to show
/// at once.
List<Place>? cachedPlaces(int? tripId, int revision, {DaySpan? dates}) {
  final c = _cache[(tripId, dates)];
  return c != null && c.$1 == revision ? c.$2 : null;
}

/// Every place with photos, optionally only on [tripId] and within
/// [dates]; oldest first. The grouping runs off the main thread, so the
/// screen stays smooth.
Future<List<Place>> loadPlaces(AppDb db, {int? tripId, DaySpan? dates, int revision = -1}) async {
  final cached = cachedPlaces(tripId, revision, dates: dates);
  if (cached != null) return cached;
  final shots = await db.photoLocations(tripId: tripId, dates: dates);
  final tags = await db.tagsFor([for (final s in shots) s.id]);
  final places = await Isolate.run(() {
    final places = groupPlaces(shots);
    namePlaces(places, tags);
    return places;
  });
  _cache[(tripId, dates)] = (revision, places);
  return places;
}
