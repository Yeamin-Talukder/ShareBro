import 'dart:convert' show utf8;
import 'dart:io' show gzip;
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import 'db.dart';
import 'places.dart';

/// Offline place names (GeoNames, CC BY 4.0; see tool/make_places.py):
/// every town in the world with 500+ people, plus every village, beach,
/// hill and landmark in Bangladesh. Nothing is looked up online.
const _placesAsset = 'assets/geo/places.tsv.gz';
const _countriesAsset = 'assets/geo/countries.tsv';

/// A named place with photos near it.
class PlaceName {
  PlaceName(this.name, this.spellings, this.country, this.population, this.photos);

  final String name;

  /// Other ways to write it ("Cox's Bazar", "Coxs Bazar").
  final List<String> spellings;
  final String country;
  final int population;

  /// Photos taken around it, newest first.
  final List<String> photos;
}

/// Where your photos were taken, by name: towns and spots with photos near
/// them, countries, and each map place's nearest town.
class PlaceIndex {
  PlaceIndex(this.places, this.countries, this.towns);

  final List<PlaceName> places;

  /// Country name -> its photos, newest first.
  final Map<String, List<String>> countries;

  /// Map place number -> (nearest town, country).
  final Map<int, (String, String)> towns;

  static final empty = PlaceIndex(const [], const {}, const {});
}

/// Indexes already worked out, by what they cover (a few at most).
final _cache = <Object, PlaceIndex>{};

/// The place index for the whole library (for search), kept until the
/// library changes.
Future<PlaceIndex> placeIndex(AppDb db, {required int revision}) async =>
    placeIndexFor(await loadPlaces(db, revision: revision), ('all', revision));

/// The place index for [places] (e.g. one trip's, or one date range's),
/// worked out off the main thread and remembered under [cacheKey].
Future<PlaceIndex> placeIndexFor(List<Place> places, Object cacheKey) async {
  final cached = _cache[cacheKey];
  if (cached != null) return cached;
  if (places.isEmpty) return PlaceIndex.empty;
  final gz = (await rootBundle.load(_placesAsset)).buffer.asUint8List();
  final countries = await rootBundle.loadString(_countriesAsset);
  final spots = [
    for (final p in places)
      (number: p.number, lat: p.lat, lng: p.lng, photos: p.photos, times: [for (final t in p.times) t.millisecondsSinceEpoch]),
  ];
  final index = await Isolate.run(() => buildPlaceIndex(gzip.decode(gz), countries, spots));
  if (_cache.length > 6) _cache.remove(_cache.keys.first);
  _cache[cacheKey] = index;
  return index;
}

/// How far around a place counts as "at" it: villages and beaches a few
/// kilometres, big cities more.
double reachKm(int population) => (6 + 2.5 * math.log(population + 1) / math.ln10).clamp(8.0, 25.0);

/// Builds the index from the place list ([rows]: the unzipped TSV) and the
/// map's places (each a spot with its photos). Pure, for the isolate and
/// for tests.
PlaceIndex buildPlaceIndex(
  List<int> rows,
  String countryTsv,
  List<({int number, double lat, double lng, List<String> photos, List<int> times})> spots,
) {
  final countryName = <String, String>{
    for (final line in countryTsv.split('\n'))
      if (line.contains('\t')) line.split('\t')[0]: line.split('\t')[1].trim(),
  };
  // Only the parts of the world near your photos are read in full: a grid of
  // quarter-degree cells around each spot.
  const cell = 0.25;
  int key(double lat, double lng) => ((lat / cell).floor() + 400) * 2000 + ((lng / cell).floor() + 800);
  final wanted = <int>{};
  for (final s in spots) {
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        wanted.add(key(s.lat + dy * cell, s.lng + dx * cell));
      }
    }
  }

  final hits = <int, ({String name, List<String> spellings, String cc, int pop, Map<String, int> photos})>{};
  final towns = <int, (String, String, double)>{};
  var row = 0;
  for (final line in utf8.decode(rows).split('\n')) {
    row++;
    final f = line.split('\t');
    if (f.length < 6) continue;
    final lat = int.parse(f[1]) / 1e4, lng = int.parse(f[2]) / 1e4;
    if (!wanted.contains(key(lat, lng))) continue;
    final pop = int.tryParse(f[4]) ?? 0;
    final reach = reachKm(pop);
    for (final s in spots) {
      final km = _km(lat, lng, s.lat, s.lng);
      if (km > reach) continue;
      final h = hits.putIfAbsent(row, () => (
            name: f[0],
            spellings: f.length > 6 && f[6].isNotEmpty ? f[6].split('|') : const <String>[],
            cc: f[3],
            pop: pop,
            photos: <String, int>{},
          ));
      for (var i = 0; i < s.photos.length; i++) {
        h.photos[s.photos[i]] = s.times[i];
      }
      // The spot's town: the closest, nudged toward bigger places.
      final score = km - 1.5 * math.log(pop + 1) / math.ln10;
      final best = towns[s.number];
      if (best == null || score < best.$3) towns[s.number] = (f[0], f[3], score);
    }
  }

  List<String> newestFirst(Map<String, int> m) =>
      (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).map((e) => e.key).toList();

  final byCountry = <String, Map<String, int>>{};
  for (final s in spots) {
    final t = towns[s.number];
    final name = t == null ? null : countryName[t.$2];
    if (name == null) continue;
    final m = byCountry.putIfAbsent(name, () => {});
    for (var i = 0; i < s.photos.length; i++) {
      m[s.photos[i]] = s.times[i];
    }
  }
  return PlaceIndex(
    [
      for (final h in hits.values)
        PlaceName(h.name, h.spellings, countryName[h.cc] ?? h.cc, h.pop, newestFirst(h.photos)),
    ]..sort((a, b) => b.population.compareTo(a.population)),
    {for (final e in byCountry.entries) e.key: newestFirst(e.value)},
    {for (final e in towns.entries) e.key: (e.value.$1, countryName[e.value.$2] ?? e.value.$2)},
  );
}

/// Kilometres between two points (haversine).
double _km(double lat1, double lng1, double lat2, double lng2) => distanceMeters(lat1, lng1, lat2, lng2) / 1000;
