import 'dart:math' as math;
import 'dart:typed_data';

/// Similarity (cosine, on L2-normalized embeddings) above which two faces are
/// treated as the same person. Lower = more merging, higher = more splitting.
/// Splitting is cheap to fix in the UI (merge), wrong merges are annoying, so
/// the defaults lean strict.
class GroupingThresholds {
  const GroupingThresholds({
    this.assign = 0.50,
    this.cluster = 0.50,
    this.merge = 0.55,
    this.minGroupSize = 2,
  });

  /// From the settings slider: 0 = loose (groups more), 1 = strict.
  factory GroupingThresholds.fromStrictness(double s) {
    final base = 0.38 + 0.24 * s.clamp(0.0, 1.0);
    return GroupingThresholds(assign: base, cluster: base, merge: base + 0.05);
  }

  /// Slider position matching the defaults above.
  static const defaultStrictness = 0.5;

  /// Joining an existing person.
  final double assign;

  /// Joining a new group being formed in this pass.
  final double cluster;

  /// Merging two new groups whose averages are close.
  final double merge;

  /// New groups smaller than this stay unsorted until more photos arrive.
  final int minGroupSize;
}

class GroupingInput {
  GroupingInput(this.faceIds, this.embeddings, this.personIds, this.locked,
      this.thresholds);

  final List<int> faceIds;
  final List<Float32List> embeddings;
  final List<int?> personIds;
  final List<bool> locked;
  final GroupingThresholds thresholds;
}

class GroupingResult {
  GroupingResult(this.assignToExisting, this.newGroups);

  final Map<int, int> assignToExisting;
  final List<List<int>> newGroups;
}

/// Running sum of member embeddings; its direction is the group's average.
class _Centroid {
  _Centroid(int dim) : sum = Float32List(dim);

  final Float32List sum;
  final List<int> members = [];
  double _norm = 0;

  void add(Float32List v, int faceIndex) {
    for (var i = 0; i < sum.length; i++) {
      sum[i] += v[i];
    }
    members.add(faceIndex);
    _updateNorm();
  }

  void absorb(_Centroid other) {
    for (var i = 0; i < sum.length; i++) {
      sum[i] += other.sum[i];
    }
    members.addAll(other.members);
    _updateNorm();
  }

  void _updateNorm() {
    var n = 0.0;
    for (var i = 0; i < sum.length; i++) {
      n += sum[i] * sum[i];
    }
    _norm = math.sqrt(n);
  }

  /// Cosine similarity to a unit-length vector.
  double similarity(Float32List v) {
    if (_norm == 0) return 0;
    var dot = 0.0;
    for (var i = 0; i < sum.length; i++) {
      dot += sum[i] * v[i];
    }
    return dot / _norm;
  }

  double similarityTo(_Centroid other) {
    if (_norm == 0 || other._norm == 0) return 0;
    var dot = 0.0;
    for (var i = 0; i < sum.length; i++) {
      dot += sum[i] * other.sum[i];
    }
    return dot / (_norm * other._norm);
  }
}

/// Groups every face that has no person yet. Runs in a background isolate.
///
/// 1. Faces close to an existing person's average join that person.
/// 2. The rest form new groups greedily (leader clustering).
/// 3. New groups whose averages are close get merged.
GroupingResult groupFaces(GroupingInput input) {
  final t = input.thresholds;
  if (input.embeddings.isEmpty) return GroupingResult({}, []);
  final dim = input.embeddings.first.length;

  final existing = <int, _Looks>{};
  for (var i = 0; i < input.faceIds.length; i++) {
    final pid = input.personIds[i];
    if (pid != null) {
      existing.putIfAbsent(pid, () => _Looks(dim)).add(input.embeddings[i], i);
    }
  }

  final assign = <int, int>{};
  final fresh = <_Centroid>[];
  for (var i = 0; i < input.faceIds.length; i++) {
    if (input.personIds[i] != null || input.locked[i]) continue;
    final v = input.embeddings[i];

    int? bestPerson;
    var best = t.assign;
    for (final e in existing.entries) {
      final s = e.value.similarity(v);
      if (s >= best) {
        best = s;
        bestPerson = e.key;
      }
    }
    if (bestPerson != null) {
      existing[bestPerson]!.add(v, i);
      assign[input.faceIds[i]] = bestPerson;
      continue;
    }

    _Centroid? bestGroup;
    best = t.cluster;
    for (final c in fresh) {
      final s = c.similarity(v);
      if (s >= best) {
        best = s;
        bestGroup = c;
      }
    }
    if (bestGroup == null) {
      bestGroup = _Centroid(dim);
      fresh.add(bestGroup);
    }
    bestGroup.add(v, i);
  }

  // Only groups that already have several faces take part in merging: their
  // averages are reliable, and skipping singletons keeps this pass fast.
  final solid = [
    for (final c in fresh)
      if (c.members.length >= t.minGroupSize) c,
  ];
  var changed = true;
  while (changed) {
    changed = false;
    for (var a = 0; a < solid.length; a++) {
      for (var b = solid.length - 1; b > a; b--) {
        if (solid[a].similarityTo(solid[b]) >= t.merge) {
          solid[a].absorb(solid.removeAt(b));
          changed = true;
        }
      }
    }
  }

  final groups = [
    for (final c in solid) [for (final i in c.members) input.faceIds[i]],
  ];
  return GroupingResult(assign, groups);
}

class SuggestInput {
  SuggestInput(this.people, this.candidates, this.minSimilarity);

  /// Named person id -> embeddings of their faces.
  final Map<int, List<Float32List>> people;

  /// Unsorted face id -> embedding.
  final Map<int, Float32List> candidates;
  final double minSimilarity;
}

/// For each unsorted face, the named person it looks most like, if any is
/// close enough to be worth asking about. Sorted most-confident first.
List<({int faceId, int personId, double similarity})> suggestMatches(
    SuggestInput input) {
  if (input.people.isEmpty) return const [];
  final dim = input.people.values.first.first.length;
  final centroids = <int, _Looks>{};
  input.people.forEach((pid, faces) {
    final c = centroids[pid] = _Looks(dim);
    for (final v in faces) {
      c.add(v, 0);
    }
  });
  final out = <({int faceId, int personId, double similarity})>[];
  input.candidates.forEach((faceId, v) {
    int? bestId;
    var best = input.minSimilarity;
    centroids.forEach((pid, c) {
      final s = c.similarity(v);
      if (s >= best) {
        best = s;
        bestId = pid;
      }
    });
    if (bestId != null) {
      out.add((faceId: faceId, personId: bestId!, similarity: best));
    }
  });
  out.sort((a, b) => b.similarity.compareTo(a.similarity));
  return out;
}

/// How many people grouping from scratch would produce at [thresholds],
/// for the settings preview. Named people count as one each.
int previewGroupCount(GroupingInput input) {
  final named = {
    for (var i = 0; i < input.faceIds.length; i++)
      if (input.personIds[i] != null) input.personIds[i],
  };
  return named.length + groupFaces(input).newGroups.length;
}

/// Faces closer than this to one of a person's looks join that look;
/// otherwise they start a new look (beard / no beard, glasses, years apart).
const _lookSimilarity = 0.62;
const _maxLooks = 6;

/// A person as several "looks" instead of one average, so the same person
/// with and without glasses, or as a child and an adult, still matches.
class _Looks {
  _Looks(this.dim);

  final int dim;
  final List<_Centroid> looks = [];

  void add(Float32List v, int faceIndex) {
    _Centroid? best;
    var bestSim = _lookSimilarity;
    for (final l in looks) {
      final s = l.similarity(v);
      if (s >= bestSim) {
        bestSim = s;
        best = l;
      }
    }
    if (best == null && looks.length < _maxLooks) {
      best = _Centroid(dim);
      looks.add(best);
    }
    // Over the limit: fold into the closest look anyway.
    best ??= looks.reduce((a, b) => a.similarity(v) >= b.similarity(v) ? a : b);
    best.add(v, faceIndex);
  }

  /// Similarity to whichever look is closest.
  double similarity(Float32List v) {
    var best = 0.0;
    for (final l in looks) {
      final s = l.similarity(v);
      if (s > best) best = s;
    }
    return best;
  }

  double similarityTo(_Looks other) {
    var best = 0.0;
    for (final a in looks) {
      for (final b in other.looks) {
        final s = a.similarityTo(b);
        if (s > best) best = s;
      }
    }
    return best;
  }
}

class MergeInput {
  MergeInput(this.people, this.dismissed, this.low, this.high);

  /// Person id -> embeddings of their faces.
  final Map<int, List<Float32List>> people;

  /// Pairs the user already said are different people (smaller id first).
  final Set<(int, int)> dismissed;
  final double low, high;
}

/// Pairs of people that look alike but weren't merged automatically:
/// "might be the same person?" Most alike first.
List<({int a, int b, double similarity})> suggestMerges(MergeInput input) {
  if (input.people.length < 2) return const [];
  final dim = input.people.values.first.first.length;
  final looks = <int, _Looks>{};
  input.people.forEach((pid, faces) {
    final l = looks[pid] = _Looks(dim);
    for (final v in faces) {
      l.add(v, 0);
    }
  });
  final ids = looks.keys.toList()..sort();
  final out = <({int a, int b, double similarity})>[];
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      if (input.dismissed.contains((ids[i], ids[j]))) continue;
      final s = looks[ids[i]]!.similarityTo(looks[ids[j]]!);
      if (s >= input.low && s < input.high) {
        out.add((a: ids[i], b: ids[j], similarity: s));
      }
    }
  }
  out.sort((x, y) => y.similarity.compareTo(x.similarity));
  return out;
}
