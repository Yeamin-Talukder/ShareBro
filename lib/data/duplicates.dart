import '../face/tags.dart';
import 'db.dart';

/// Shots this close in time can be "the same moment".
const _maxGapMs = 20 * 1000;

/// Hashes differing in at most this many of 64 bits look the same.
const _maxBits = 10;

/// A set of near-identical photos and which one looks best.
class DuplicateSet {
  DuplicateSet(this.photos, this.best);

  /// Oldest first.
  final List<PhotoFingerprint> photos;
  final String best;

  bool get allExtrasHidden =>
      photos.where((p) => p.assetId != best).every((p) => p.hidden);

  List<String> get extras => [
        for (final p in photos)
          if (p.assetId != best) p.assetId,
      ];
}

/// Groups bursts and repeated poses: photos taken within seconds of each
/// other whose fingerprints nearly match. [photos] must be in time order.
List<DuplicateSet> findDuplicates(List<PhotoFingerprint> photos) {
  final sets = <DuplicateSet>[];
  var current = <PhotoFingerprint>[];

  void close() {
    if (current.length >= 2) {
      final best = current.reduce((a, b) => b.quality > a.quality ? b : a);
      sets.add(DuplicateSet(current, best.assetId));
    }
    current = [];
  }

  for (final p in photos) {
    if (current.isNotEmpty) {
      final anchor = current.first;
      final last = current.last;
      final same = p.takenAt - last.takenAt <= _maxGapMs &&
          hammingDistance(p.hash, anchor.hash) <= _maxBits;
      if (!same) close();
    }
    current.add(p);
  }
  close();
  return sets;
}
