import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/data/group_shots.dart';
import 'package:photo_organizer/data/search.dart';

void main() {
  final vocab = SearchVocabulary(
    people: [
      (id: 1, name: 'Maya Lopez', nickname: 'Mimi'),
      (id: 2, name: 'Leo Park', nickname: null),
      (id: 3, name: 'Sam Lee', nickname: null),
      (id: 4, name: 'Sam Ortiz', nickname: null),
    ],
    trips: [(id: 7, name: 'Goa Trip')],
    tags: {'selfie': 'Selfies', 'label:Beach': 'Beach', 'label:Food': 'Food'},
  );
  final now = DateTime(2026, 10, 31);

  test('search understands people, places and trips together', () {
    final r = vocab.parse("Maya and Leo's beach selfie in Goa", now: now);
    expect([for (final t in r.terms) t.label], ['Maya Lopez', 'Leo Park', 'Beach', 'Selfies', 'Goa Trip']);
    expect(r.unknown, isEmpty);
  });

  test('nicknames work, and a shared first name needs the surname', () {
    expect(vocab.parse('mimi', now: now).terms.single.personId, 1);
    expect(vocab.parse('sam', now: now).unknown, ['sam']);
    expect(vocab.parse('sam ortiz', now: now).terms.single.personId, 4);
  });

  test('typed names lose stray spaces', () {
    expect(AppDb.cleanName('  Maya   Lopez \n'), 'Maya Lopez');
    expect(AppDb.cleanName('   '), '');
  });

  test('men and women find photos by gender', () {
    final r = vocab.parse('women beach', now: now);
    expect(r.terms.first.gender, Gender.female);
    expect(r.unknown, isEmpty);
    expect(vocab.parse('boys', now: now).terms.single.gender, Gender.male);
    // A person's name still wins.
    expect(vocab.parse('maya', now: now).terms.single.personId, 1);
  });

  test('months and years become date spans', () {
    final june = vocab.parse('food june', now: now).terms.last.dates!;
    expect(june.start, DateTime(2026, 6));
    expect(june.end.day, 30);
    final dec = vocab.parse('dec 2024', now: now).terms.single;
    expect(dec.label, 'December 2024');
    // December hasn't started yet this year, so it means last year's.
    expect(vocab.parse('december', now: now).terms.single.dates!.start, DateTime(2025, 12));
    expect(vocab.parse('2025', now: now).terms.single.dates!.end.year, 2025);
  });

  test('suggestions finish the last word', () {
    expect([for (final s in vocab.suggest('be')) s.label], ['Beach']);
    expect(vocab.suggest('le').first.label, 'Leo Park');
  });

  GroupShot shot(String id, int sec, List<(double, double)> faces) =>
      GroupShot(id, sec * 1000, [for (final (eyes, smile) in faces) ShotFace(0.12, eyes, smile, 120)]);

  test('the burst shot with everyone\'s eyes open wins', () {
    final bursts = findBursts([
      shot('a', 0, [(0.9, 0.8), (0.05, 0.9), (0.9, 0.2)]),
      shot('b', 4, [(0.9, 0.8), (0.95, 0.9), (0.9, 0.6)]),
      shot('c', 9, [(0.1, 0.8), (0.9, 0.9), (0.9, 0.6)]),
      // Ten minutes later: another moment, alone, so not a burst.
      shot('d', 600, [(0.9, 0.8), (0.9, 0.9)]),
    ]);
    expect(bursts, hasLength(1));
    expect(bursts.single.bestShot.assetId, 'b');
    expect(bursts.single.others, ['a', 'c']);
    expect(bursts.single.reason, startsWith('Everyone\'s eyes open'));
  });
}
