import 'db.dart';

/// Shots further apart than this start a new burst.
const _maxGapMs = 30 * 1000;

/// A burst never spans more than this, however steady the shooting.
const _maxSpanMs = 3 * 60 * 1000;

/// Eye-open chance below this is a blink; sharpness below this is blurry
/// (the same limits Explore uses).
const _blink = 0.2;
const _blurry = 60.0;

/// One group photo with how good it came out.
class ScoredShot {
  ScoredShot(this.shot, this.score, this.blinks, this.blurry, this.smiles);

  final GroupShot shot;
  final double score;

  /// Faces with eyes closed, blurry faces, and smiling faces.
  final int blinks, blurry, smiles;

  String get assetId => shot.assetId;
  int get faceCount => shot.faces.length;
}

/// Several group photos of the same moment, and the one to keep.
class ShotBurst {
  ShotBurst(this.shots) : best = shots.indexOf(shots.reduce((a, b) => b.score > a.score ? b : a));

  /// Oldest first.
  final List<ScoredShot> shots;
  final int best;

  ScoredShot get bestShot => shots[best];

  List<String> get others => [
        for (final (i, s) in shots.indexed)
          if (i != best) s.assetId,
      ];

  /// Why the best one won, in a few words.
  String get reason {
    final b = bestShot;
    final rest = [for (final (i, s) in shots.indexed) if (i != best) s];
    final parts = <String>[];
    if (b.blinks == 0 && rest.any((s) => s.blinks > 0)) parts.add('Everyone\'s eyes open');
    if (b.faceCount > rest.map((s) => s.faceCount).fold(0, (a, n) => n > a ? n : a)) parts.add('everyone in');
    if (b.smiles > 0 && rest.every((s) => s.smiles < b.smiles)) parts.add('most smiles');
    if (b.blurry == 0 && rest.any((s) => s.blurry > 0)) parts.add('sharpest');
    if (parts.isEmpty) return 'Best faces overall';
    final text = parts.join(', ');
    return text[0].toUpperCase() + text.substring(1);
  }
}

/// Groups [shots] (in time order) into bursts of 2+ photos of the same
/// moment and scores each one: open eyes count most, then smiles, then
/// sharp faces, then having everyone in the frame. Newest burst first.
List<ShotBurst> findBursts(List<GroupShot> shots) {
  final bursts = <ShotBurst>[];
  var current = <GroupShot>[];

  void close() {
    if (current.length >= 2) {
      final most = current.map((s) => s.faces.length).reduce((a, b) => a > b ? a : b);
      bursts.add(ShotBurst([for (final s in current) _score(s, most)]));
    }
    current = [];
  }

  for (final s in shots) {
    if (current.isNotEmpty) {
      final last = current.last;
      final same = s.takenAt - last.takenAt <= _maxGapMs &&
          s.takenAt - current.first.takenAt <= _maxSpanMs &&
          (s.faces.length - last.faces.length).abs() <= 1;
      if (!same) close();
    }
    current.add(s);
  }
  close();
  return bursts.reversed.toList();
}

ScoredShot _score(GroupShot s, int most) {
  var sum = 0.0;
  var blinks = 0, blurry = 0, smiles = 0;
  for (final f in s.faces) {
    final eyes = f.eyesOpen ?? 0.7;
    final smile = f.smile ?? 0.3;
    final sharp = ((f.sharpness ?? 80) / 150).clamp(0.0, 1.0);
    if (f.eyesOpen != null && f.eyesOpen! < _blink) blinks++;
    if (f.sharpness != null && f.sharpness! < _blurry) blurry++;
    if (smile > 0.7) smiles++;
    sum += 0.5 * eyes + 0.25 * smile + 0.25 * sharp;
  }
  final n = s.faces.length;
  final score = sum / n - 0.15 * blinks - 0.05 * blurry + 0.2 * n / most;
  return ScoredShot(s, score, blinks, blurry, smiles);
}
