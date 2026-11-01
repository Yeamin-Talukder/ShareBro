import 'dart:convert';
import 'dart:typed_data';

import 'db.dart';

/// Where a profile's face came from, for the profile screen.
enum FaceSource { selfie, upload, people }

/// The phone owner's face, set up once and used wherever the app needs to
/// know who you are (trip groups, and later anything else). Only the face
/// fingerprints and one small face crop are kept, never the photos.
class FaceProfile {
  FaceProfile({required this.faces, this.thumb, this.source, this.personId});

  /// One fingerprint per sample (selfie, uploaded photo, or face from People).
  final List<Float32List> faces;

  /// A small crop of the clearest face, for the avatar.
  final Uint8List? thumb;
  final FaceSource? source;

  /// The person in People this profile was taken from, if any.
  final int? personId;

  bool get isSet => faces.isNotEmpty;

  /// Samples that make a solid profile; more only help a little.
  static const enough = 3;

  /// Most samples kept (newest win).
  static const maxFaces = 24;

  static const _key = 'profile_face';

  static Future<FaceProfile> load(AppDb db) async {
    final raw = await db.setting(_key);
    if (raw == null || raw.isEmpty) return FaceProfile(faces: const []);
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return FaceProfile(faces: const []);
    }
  }

  Future<void> save(AppDb db) => db.setSetting(_key, isSet ? jsonEncode(toJson()) : '');

  FaceProfile adding(List<Float32List> more, {Uint8List? thumb, FaceSource? source}) {
    final all = [...faces, ...more];
    return FaceProfile(
      faces: all.length > maxFaces ? all.sublist(all.length - maxFaces) : all,
      thumb: this.thumb ?? thumb,
      source: source ?? this.source,
      personId: personId,
    );
  }

  Map<String, dynamic> toJson() => {
        'faces': [for (final f in faces) encodeFace(f)],
        'thumb': thumb == null ? null : base64Encode(thumb!),
        'source': source?.name,
        'person': personId,
      };

  static FaceProfile fromJson(Map<String, dynamic> j) => FaceProfile(
        faces: [for (final f in (j['faces'] as List? ?? const [])) decodeFace(f as String)],
        thumb: j['thumb'] == null ? null : base64Decode(j['thumb'] as String),
        source: FaceSource.values.where((s) => s.name == j['source']).firstOrNull,
        personId: j['person'] as int?,
      );
}

/// A face fingerprint as text, for settings and for sending to a group.
String encodeFace(Float32List f) => base64Encode(f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes));

// Copy into an aligned buffer; decoded bytes may not be 4-byte aligned.
Float32List decodeFace(String s) => Float32List.fromList(Uint8List.fromList(base64Decode(s)).buffer.asFloat32List());
