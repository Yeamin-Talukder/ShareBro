import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/places.dart';
import 'package:photo_organizer/ui/places_screen.dart';

void main() {
  final day = DateTime(2026, 6, 12, 9);
  // Many places: a tight cluster in town and a few far away, the case
  // where one fixed view made the route unreadable.
  final shots = [
    for (var i = 0; i < 6; i++) (id: 't$i', at: day.add(Duration(hours: i)), lat: 15.50 + i * 0.004, lng: 73.82 + i * 0.003),
    (id: 'far1', at: day.add(const Duration(days: 1)), lat: 15.30, lng: 74.30),
    (id: 'far2', at: day.add(const Duration(days: 2)), lat: 15.01, lng: 74.02),
  ];
  final places = groupPlaces(shots);
  const size = Size(400, 800);
  final setup = journeySetup(places, size, 0);
  final plan = setup.plan;
  final clear = Rect.fromCenter(center: plan.focal, width: plan.view.width, height: plan.view.height);

  test('projection goes there and back', () {
    final p = places.first;
    final back = setup.proj.unproject(setup.proj.of(p));
    expect(back.lat, closeTo(p.lat, 1e-9));
    expect(back.lng, closeTo(p.lng, 1e-9));
  });

  test('it opens on the whole trip', () {
    final m = plan.at(0);
    expect(m.camera.scale, 1);
    for (final s in setup.stops) {
      expect(clear.inflate(1).contains(m.camera.toScreen(s, plan.focal)), isTrue);
    }
  });

  test('each leg keeps both of its ends on screen, then closes in on arrival', () {
    for (var i = 0; i + 1 < places.length; i++) {
      final mid = plan.at(plan.restStart(i) + 1.6 + 2.6 * 0.5);
      expect(mid.leg, i);
      for (final s in [setup.stops[i], setup.stops[i + 1]]) {
        expect(clear.inflate(1).contains(mid.camera.toScreen(s, plan.focal)), isTrue, reason: 'leg $i');
      }
      final there = plan.at(plan.restStart(i + 1) + 0.1);
      expect(there.arrived, i + 1);
      expect(there.camera.scale, greaterThanOrEqualTo(mid.camera.scale));
    }
  });

  test('the town cluster gets a real close-up', () {
    final close = plan.at(plan.restStart(1) + 0.5);
    expect(close.camera.scale, greaterThan(4));
  });

  test('the route moves forward and ends at the last place', () {
    final stopAt = [for (var i = 0; i < places.length; i++) i / (places.length - 1)];
    var last = -1.0;
    for (var t = 0.0; t <= plan.duration; t += 0.25) {
      final r = plan.at(t).route(stopAt);
      expect(r, greaterThanOrEqualTo(last - 1e-9));
      last = r;
    }
    expect(plan.at(plan.duration).arrived, places.length - 1);
    expect(plan.at(plan.duration).camera.scale, closeTo(1, 1e-6));
  });
}
