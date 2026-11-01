import 'db.dart';

enum TermKind { person, trip, tag, dates }

/// One thing the search understood: a person, a trip, a category or scene,
/// or a span of dates.
class SearchTerm {
  const SearchTerm(this.kind, this.label, {this.personId, this.tag, this.tripId, this.dates});

  final TermKind kind;

  /// How it's shown: "Maya", "Beach", "June 2026".
  final String label;
  final int? personId;
  final String? tag;
  final int? tripId;
  final DaySpan? dates;

  String get key => '${kind.name}:${personId ?? tag ?? tripId ?? dates?.start.millisecondsSinceEpoch}';

  @override
  bool operator ==(Object other) => other is SearchTerm && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// Words that join things up but don't filter anything.
const _filler = {
  'and', 'with', 'at', 'in', 'on', 'the', 'of', 'photos', 'photo', 'pics', 'pictures', 'from', 'during', 'a',
  'an', 'to', 'all', 'my', 'me', 'or', 'by', 'shots', 'trip',
};

const _monthNames = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
];

/// Longest phrase (in words) that's looked up as one thing.
const _maxPhrase = 4;

/// Everything a search can name, built from the people, trips and
/// categories in the library.
class SearchVocabulary {
  SearchVocabulary({
    List<({int id, String name, String? nickname})> people = const [],
    List<({int id, String name})> trips = const [],
    Map<String, String> tags = const {},
  }) {
    // First come, first served: people beat trips beat categories.
    final firstNames = <String, int>{};
    for (final p in people) {
      final first = _words(p.name).firstOrNull;
      if (first != null) firstNames[first] = (firstNames[first] ?? 0) + 1;
    }
    for (final p in people) {
      final t = SearchTerm(TermKind.person, p.name, personId: p.id);
      _add(p.name, t);
      if (p.nickname != null) _add(p.nickname!, t);
      // "Maya" finds Maya Lopez, unless there are two Mayas.
      final first = _words(p.name).firstOrNull;
      if (first != null && firstNames[first] == 1) _add(first, t);
    }
    for (final trip in trips) {
      _add(trip.name, SearchTerm(TermKind.trip, trip.name, tripId: trip.id));
    }
    tags.forEach((tag, title) {
      final t = SearchTerm(TermKind.tag, title, tag: tag);
      _add(title, t);
      // "selfie" as well as "selfies".
      final words = _words(title);
      if (words.isNotEmpty && words.last.length > 3 && words.last.endsWith('s')) {
        _add([...words.take(words.length - 1), words.last.substring(0, words.last.length - 1)].join(' '), t);
      }
    });
  }

  final Map<String, SearchTerm> _phrases = {};

  void _add(String phrase, SearchTerm t) {
    final key = _words(phrase).where((w) => !_filler.contains(w)).join(' ');
    if (key.isNotEmpty) _phrases.putIfAbsent(key, () => t);
  }

  static List<String> _words(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"['’]s\b"), '')
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.isNotEmpty)
      .toList();

  /// What [query] names, and the words it couldn't place.
  ({List<SearchTerm> terms, List<String> unknown}) parse(String query, {DateTime? now}) {
    final words = _words(query).where((w) => !_filler.contains(w)).toList();
    final terms = <SearchTerm>[];
    final unknown = <String>[];
    var i = 0;
    while (i < words.length) {
      final date = _date(words, i, now ?? DateTime.now());
      if (date != null) {
        if (!terms.contains(date.$1)) terms.add(date.$1);
        i += date.$2;
        continue;
      }
      SearchTerm? hit;
      var used = 0;
      for (var n = _maxPhrase; n >= 1 && hit == null; n--) {
        if (i + n > words.length) continue;
        hit = _phrases[words.sublist(i, i + n).join(' ')];
        used = n;
      }
      if (hit == null) {
        unknown.add(words[i]);
        i++;
      } else {
        if (!terms.contains(hit)) terms.add(hit);
        i += used;
      }
    }
    return (terms: terms, unknown: unknown);
  }

  /// Things with a word starting like the last word typed, to finish it
  /// with a tap. People first.
  List<SearchTerm> suggest(String query, {int limit = 6}) {
    final last = _words(query).lastOrNull;
    if (last == null) return const [];
    final out = <SearchTerm>[];
    for (final e in _phrases.entries) {
      if (e.key != last && e.key.split(' ').any((w) => w.startsWith(last)) && !out.contains(e.value)) {
        out.add(e.value);
      }
    }
    out.sort((a, b) => a.kind.index.compareTo(b.kind.index));
    return out.take(limit).toList();
  }

  /// "june", "june 2025", "2025", "today" or "yesterday" at [i]: the span
  /// and how many words it took.
  static (SearchTerm, int)? _date(List<String> words, int i, DateTime now) {
    final w = words[i];
    final today = DateTime(now.year, now.month, now.day);
    if (w == 'today') return (SearchTerm(TermKind.dates, 'Today', dates: DaySpan(today, today)), 1);
    if (w == 'yesterday') {
      final y = today.subtract(const Duration(days: 1));
      return (SearchTerm(TermKind.dates, 'Yesterday', dates: DaySpan(y, y)), 1);
    }
    final year = _year(w, now);
    if (year != null) {
      return (SearchTerm(TermKind.dates, '$year', dates: DaySpan(DateTime(year), DateTime(year, 12, 31))), 1);
    }
    final m = w.length < 3 ? -1 : _monthNames.indexWhere((name) => name.startsWith(w));
    if (m < 0) return null;
    final next = i + 1 < words.length ? _year(words[i + 1], now) : null;
    // A month on its own means the last one that has started.
    final y = next ?? (m + 1 <= now.month ? now.year : now.year - 1);
    final name = _monthNames[m][0].toUpperCase() + _monthNames[m].substring(1);
    return (
      SearchTerm(TermKind.dates, '$name $y', dates: DaySpan(DateTime(y, m + 1), DateTime(y, m + 2, 0))),
      next == null ? 1 : 2,
    );
  }

  static int? _year(String w, DateTime now) {
    final y = w.length == 4 ? int.tryParse(w) : null;
    return y != null && y >= 1990 && y <= now.year + 1 ? y : null;
  }
}

/// Photos matching every term, newest first: all the people together, in
/// every category, inside the trip and the dates.
Future<List<String>> runSearch(AppDb db, List<SearchTerm> terms) async {
  if (terms.isEmpty) return const [];
  final people = [for (final t in terms) ?t.personId];
  final trip = terms.where((t) => t.tripId != null).firstOrNull?.tripId;
  final dates = terms.where((t) => t.dates != null).firstOrNull?.dates;
  final lists = <List<String>>[
    if (people.isNotEmpty) await db.photosWithAll(people, tripId: trip),
    for (final t in terms)
      if (t.tag != null) await db.photosWithTag(t.tag!, dates: dates),
    if (trip != null || dates != null) await db.photosIn(tripId: trip, dates: dates),
  ];
  if (lists.isEmpty) return const [];
  lists.sort((a, b) => a.length.compareTo(b.length));
  final others = [for (final l in lists.skip(1)) l.toSet()];
  return [
    for (final id in lists.first)
      if (others.every((s) => s.contains(id))) id,
  ];
}
