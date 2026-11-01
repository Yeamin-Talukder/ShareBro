import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/places.dart';

void main() {
  final day = DateTime(2026, 6, 12, 9);
  ({String id, DateTime at, double lat, double lng}) shot(String id, int minutes, double lat, double lng) =>
      (id: id, at: day.add(Duration(minutes: minutes)), lat: lat, lng: lng);

  test('photos close together share a place; far ones start a new one', () {
    final places = groupPlaces([
      shot('a', 0, 15.5000, 73.8000),
      shot('b', 5, 15.5010, 73.8010), // ~150 m away
      shot('c', 60, 15.6000, 73.9000), // ~15 km away
      shot('d', 120, 15.5005, 73.8005), // back at the first place
    ]);
    expect(places.length, 2);
    expect(places[0].photos, ['a', 'b', 'd']);
    expect(places[1].photos, ['c']);
    expect([for (final p in places) p.number], [1, 2]);
  });

  test('places are named after what most of their photos show', () {
    final places = groupPlaces([
      shot('a', 0, 15.5, 73.8),
      shot('b', 1, 15.5, 73.8),
      shot('c', 2, 15.5, 73.8),
      shot('d', 90, 16.0, 74.0),
      shot('e', 95, 16.0, 74.0),
      shot('f', 200, 17.0, 75.0),
    ]);
    namePlaces(places, {
      'a': {'label:Beach'},
      'b': {'label:Beach', 'label:Smile'},
      'd': {'label:Beach'},
      'e': {'label:Beach'},
    });
    expect(places[0].name, 'Beach');
    expect(places[1].name, 'Beach 2');
    // Nothing stands out: numbered instead.
    expect(places[2].name, 'Place 3');
  });

  test('distance is in metres', () {
    expect(distanceMeters(0, 0, 0, 1), closeTo(111195, 50));
  });
}
