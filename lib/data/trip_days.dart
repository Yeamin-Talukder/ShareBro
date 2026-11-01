import '../face/tags.dart' show labelPrefix;
import 'db.dart';

/// Scene labels too vague to name a day after.
const _vague = {
  'Smile', 'Fun', 'Selfie', 'Event', 'Leisure', 'Sky', 'Cool', 'Crowd', 'Team', 'Pattern',
  'Darkness', 'Hand', 'Eyelash', 'Jacket', 'Shirt', 'Sunglasses', 'Hair', 'Beard', 'Flesh', 'Room',
};

/// A label needs at least this many of a day's photos to name it.
const _minPhotos = 2;

/// One day of a trip: "Day 2 · Beach".
class TripDay {
  TripDay(this.number, this.date, this.photos, this.place);

  final int number;
  final DateTime date;

  /// That day's photos, in time order.
  final List<String> photos;

  /// What most of the day's photos show, if anything stands out.
  final String? place;

  DaySpan get span => DaySpan(date, date);
  String get cover => photos[photos.length ~/ 2];
  String get label => place == null ? 'Day $number' : 'Day $number · $place';
}

/// Splits a trip into days and names each one after the scene that sets it
/// apart from the rest of the trip (the beach day, the mountain day).
Future<List<TripDay>> tripDays(AppDb db, int tripId) async {
  final shots = await db.tripTimeline(tripId);
  final byDay = <DateTime, List<String>>{};
  for (final s in shots) {
    final at = s.at;
    if (at == null) continue;
    byDay.putIfAbsent(DateTime(at.year, at.month, at.day), () => []).add(s.id);
  }
  if (byDay.isEmpty) return const [];
  final tags = await db.tagsFor([for (final ids in byDay.values) ...ids]);

  Map<String, int> labelsOf(Iterable<String> ids) {
    final n = <String, int>{};
    for (final id in ids) {
      for (final t in tags[id] ?? const <String>{}) {
        if (!t.startsWith(labelPrefix)) continue;
        final name = t.substring(labelPrefix.length);
        if (!_vague.contains(name)) n[name] = (n[name] ?? 0) + 1;
      }
    }
    return n;
  }

  final total = byDay.values.fold<int>(0, (n, ids) => n + ids.length);
  final trip = labelsOf([for (final ids in byDay.values) ...ids]);
  final days = byDay.keys.toList()..sort();
  return [
    for (final (i, d) in days.indexed)
      TripDay(i + 1, d, byDay[d]!, _place(labelsOf(byDay[d]!), byDay[d]!.length, trip, total, days.length)),
  ];
}

/// The label most typical of this day compared with the whole trip.
String? _place(Map<String, int> day, int photos, Map<String, int> trip, int total, int dayCount) {
  String? best;
  var bestScore = 0.0;
  day.forEach((name, n) {
    if (n < _minPhotos) return;
    final here = n / photos;
    // On a one-day trip, the most common scene wins.
    final elsewhere = dayCount == 1 ? 0.0 : (trip[name]! - n) / (total - photos).clamp(1, 1 << 30);
    final score = here - 0.6 * elsewhere;
    if (here >= 0.2 && score > bestScore) {
      bestScore = score;
      best = name;
    }
  });
  return best;
}
