import 'dart:typed_data';

import '../face/clustering.dart';

/// One face found in a photo picked for a trip group.
class PhotoFace {
  PhotoFace(this.assetId, this.embedding, this.thumb);

  final String assetId;
  final Float32List embedding;
  final Uint8List? thumb;
}

/// A face that looks a bit like a group member, but not enough to send
/// without asking.
class UnsureFace {
  UnsureFace(this.assetId, this.member, this.thumb, this.similarity);

  final String assetId;
  final String member;
  final Uint8List? thumb;
  final double similarity;
}

/// Who gets which of the photos you picked.
class GroupPlan {
  GroupPlan(this.order, this.send, this.unsure, this.faces);

  /// The photos, in the order they were picked.
  final List<String> order;

  /// Member key -> photos they're in, in pick order.
  final Map<String, List<String>> send;
  final List<UnsureFace> unsure;

  /// Photo -> member keys found in it for sure (for the animation).
  final Map<String, Set<String>> faces;

  /// Photos nobody else in the group is in: they stay on this phone.
  int get stay => order.where((id) => !send.values.any((l) => l.contains(id)) && !unsure.any((u) => u.assetId == id)).length;

  int get copies => send.values.fold(0, (n, l) => n + l.length);

  /// "Yes, that's them": they get the photo too.
  void accept(UnsureFace u) {
    final list = send.putIfAbsent(u.member, () => []);
    if (!list.contains(u.assetId)) {
      list.add(u.assetId);
      list.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    }
  }
}

class GroupPlanInput {
  GroupPlanInput(this.members, this.me, this.order, this.photos, this.sure, this.maybe);

  /// Member key -> their profile's face fingerprints (yours included).
  final Map<String, List<Float32List>> members;

  /// Your own key: faces of you are never sent anywhere.
  final String me;
  final List<String> order;

  /// Photo -> the faces in it.
  final Map<String, List<PhotoFace>> photos;

  /// At or above [sure] a face is that member; between [maybe] and [sure]
  /// it's asked about.
  final double sure, maybe;
}

/// Matches every face in the picked photos to the group's members. Each
/// face goes to the member it looks most like, if any is close enough;
/// photos are only for the people in them.
GroupPlan planGroup(GroupPlanInput input) {
  final keys = input.members.keys.toList();
  final faces = [for (final id in input.order) ...?input.photos[id]];
  final matches = suggestMatches(SuggestInput(
    {for (final (i, k) in keys.indexed) i: input.members[k]!},
    {for (final (i, f) in faces.indexed) i: f.embedding},
    input.maybe,
  ));
  final send = <String, List<String>>{};
  final sureIn = <String, Set<String>>{};
  final unsure = <UnsureFace>[];
  for (final m in matches) {
    final key = keys[m.personId], face = faces[m.faceId];
    if (key == input.me) continue;
    if (m.similarity >= input.sure) {
      sureIn.putIfAbsent(face.assetId, () => {}).add(key);
    } else if (!unsure.any((u) => u.assetId == face.assetId && u.member == key)) {
      unsure.add(UnsureFace(face.assetId, key, face.thumb, m.similarity));
    }
  }
  for (final id in input.order) {
    for (final key in sureIn[id] ?? const <String>{}) {
      send.putIfAbsent(key, () => []).add(id);
    }
  }
  // Someone already getting the photo for sure needn't be asked about it.
  unsure.removeWhere((u) => sureIn[u.assetId]?.contains(u.member) ?? false);
  unsure.sort((a, b) => input.order.indexOf(a.assetId).compareTo(input.order.indexOf(b.assetId)));
  return GroupPlan(input.order, send, unsure, sureIn);
}
