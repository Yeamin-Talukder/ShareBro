/// Photo categories, worked out once per photo during a scan and stored as
/// plain tags. Bump [tagVersion] when the rules change so the next scan
/// re-tags old photos.
const tagVersion = 3;

/// Scene labels from ML Kit are stored as `label:<Name>`.
const labelPrefix = 'label:';

/// Faces this sharp or less count as blurry (see the face engine).
const _blurLimit = 60.0;

/// Someone's eye-open chance below this counts as a clear blink.
const _eyesClosed = 0.2;

/// Head turned more than this (degrees) is "looking away".
const _lookingAway = 30.0;

/// Smile chance above this counts as smiling.
const _smiling = 0.7;

/// A face covering this share of the photo is "arm's length" close.
const _selfieArea = 0.045;

class PhotoFacts {
  PhotoFacts({
    required this.faceCount,
    required this.maxFaceArea,
    required this.minFaceSharpness,
    required this.width,
    required this.height,
    required this.folder,
    required this.title,
    required this.hasLocation,
    required this.labels,
    this.minEyesOpen,
    this.maxSmile,
    this.maxYaw,
  });

  /// Lowest eye-open chance of any face, highest smile chance, and the most
  /// any head is turned (degrees).
  final double? minEyesOpen, maxSmile, maxYaw;

  final int faceCount;

  /// Largest face as a share (0..1) of the whole photo.
  final double maxFaceArea;
  final double? minFaceSharpness;

  /// As displayed (already rotated).
  final int width, height;

  /// Folder inside the phone, e.g. `Pictures/Screenshots/`.
  final String folder;
  final String title;
  final bool hasLocation;
  final List<String> labels;
}

Set<String> tagsFor(PhotoFacts f) {
  final tags = <String>{};
  final folder = f.folder.toLowerCase();
  final title = f.title.toLowerCase();
  final screenshot =
      folder.contains('screenshot') || title.startsWith('screenshot');

  if (screenshot) {
    tags.add('screenshot');
  } else {
    // People
    if (f.faceCount == 0) tags.add('no_people');
    if (f.faceCount == 1) tags.add('solo');
    if (f.faceCount == 2) tags.add('couple');
    if (f.faceCount >= 3) tags.add('group');
    // A selfie: few people, faces held close to the camera.
    if (f.faceCount >= 1 && f.faceCount <= 4 && f.maxFaceArea >= _selfieArea) {
      tags.add('selfie');
    }
    if (f.minFaceSharpness != null && f.minFaceSharpness! < _blurLimit) {
      tags.add('blurry');
    }
    if (f.faceCount > 0) {
      if (f.minEyesOpen != null && f.minEyesOpen! < _eyesClosed) tags.add('eyes_closed');
      if (f.maxYaw != null && f.maxYaw! > _lookingAway) tags.add('looking_away');
      if (f.maxSmile != null && f.maxSmile! > _smiling) tags.add('smiling');
    }
    for (final l in f.labels) {
      tags.add('$labelPrefix$l');
    }
  }

  // Photo types
  // Messaging apps save into their own folders (Telegram's sits inside
  // Download), so those count as the app, not as a download.
  final whatsapp = folder.contains('whatsapp');
  final telegram = folder.contains('telegram');
  if (whatsapp) tags.add('whatsapp');
  if (telegram) tags.add('telegram');
  if (!whatsapp && !telegram && folder.contains('download')) tags.add('download');
  if (f.width > 0 && f.height > 0) {
    tags.add(f.width > f.height ? 'landscape' : 'portrait');
  }
  if (f.hasLocation) tags.add('location');
  return tags;
}

/// Overall 0..1 score for picking the best of near-identical shots: sharp
/// faces with eyes open and smiles win. Photos without faces score 0.5.
double photoQuality({
  required int faceCount,
  double? avgSharpness,
  double? minEyesOpen,
  double? maxSmile,
}) {
  if (faceCount == 0) return 0.5;
  final sharp = ((avgSharpness ?? 100) / 200).clamp(0.05, 1.0);
  final eyes = (minEyesOpen ?? 0.8).clamp(0.15, 1.0);
  final smile = 0.7 + 0.3 * (maxSmile ?? 0.5);
  return sharp * eyes * smile;
}

/// 64-bit "difference hash" of a 9x8 grayscale image: near-identical photos
/// get hashes that differ in only a few bits.
int differenceHash(List<int> gray9x8) {
  var hash = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      hash <<= 1;
      if (gray9x8[y * 9 + x] < gray9x8[y * 9 + x + 1]) hash |= 1;
    }
  }
  return hash;
}

/// How many bits differ between two hashes.
int hammingDistance(int a, int b) {
  var v = a ^ b;
  var n = 0;
  while (v != 0) {
    v &= v - 1;
    n++;
  }
  return n;
}
