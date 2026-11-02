import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/gazetteer.dart';
import 'package:photo_organizer/data/search.dart';

void main() {
  final countries = File('assets/geo/countries.tsv').readAsStringSync();
  final rows = gzip.decode(File('assets/geo/places.tsv.gz').readAsBytesSync());

  // Two made-up photo spots: on the beach at Kuakata, and in Cox's Bazar.
  final spots = [
    (number: 1, lat: 21.8160, lng: 90.1240, photos: ['beach1', 'beach2'], times: [1000, 2000]),
    (number: 2, lat: 21.4300, lng: 92.0050, photos: ['cox1'], times: [3000]),
  ];

  test('the bundled list knows Kuakata, and finds the beach photos there', () {
    final index = buildPlaceIndex(rows, countries, spots);
    final kuakata = index.places.firstWhere((p) => p.name == 'Kuakata');
    expect(kuakata.country, 'Bangladesh');
    expect(kuakata.photos, ['beach2', 'beach1']); // newest first
    expect(index.places.firstWhere((p) => p.name == "Cox's Bazar").photos, ['cox1']);
    expect(index.countries['Bangladesh'], containsAll(['beach1', 'beach2', 'cox1']));
  });

  test('each map place gets a town name', () {
    final index = buildPlaceIndex(rows, countries, spots);
    expect(index.towns[2]!.$1, "Cox's Bazar");
    expect(index.towns[1]!.$2, 'Bangladesh');
  });

  test('typing a place name, in any spelling, finds its photos', () {
    final index = buildPlaceIndex(rows, countries, spots);
    final vocab = SearchVocabulary(
      places: [for (final p in index.places) (name: p.name, spellings: p.spellings, photos: p.photos)],
      countries: index.countries,
    );
    final r = vocab.parse('photos in kuakata');
    expect(r.unknown, isEmpty);
    expect(r.terms.single.kind, TermKind.place);
    expect(r.terms.single.photos, ['beach2', 'beach1']);
    expect(vocab.parse("cox's bazar").terms.single.photos, ['cox1']);
    expect(vocab.parse('coxs bazar').terms.single.photos, ['cox1']);
    expect(vocab.parse('bangladesh').terms.single.photos, hasLength(3));
    expect(vocab.suggest('kua').map((t) => t.label), contains('Kuakata'));
  });

  test('a place far from every photo is left out', () {
    final index = buildPlaceIndex(utf8.encode('Faraway\t100000\t100000\tBD\t0\tP\n'), countries, spots);
    expect(index.places, isEmpty);
  });
}
