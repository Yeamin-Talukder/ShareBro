import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// A face picture from its bytes that counts as the same image as any other
/// with the same bytes.
///
/// [MemoryImage] compares the byte list itself, not its contents. People
/// lists are read again from the database after every change (and often
/// during a scan), which gives every face new but identical bytes: each
/// MemoryImage then misses the image cache, is decoded again, and the face
/// flashes empty for a frame. Comparing by content finds the decoded
/// picture already in the cache, so nothing blinks.
class FaceImage extends MemoryImage {
  FaceImage(super.bytes) : _hash = _hashOf(bytes);

  final int _hash;

  /// A quick fingerprint: the length and up to 256 bytes spread over the
  /// file. Equality still checks every byte.
  static int _hashOf(Uint8List b) {
    var h = b.length;
    final step = b.length > 256 ? b.length ~/ 256 : 1;
    for (var i = 0; i < b.length; i += step) {
      h = 0x1fffffff & (h * 31 + b[i]);
    }
    return h;
  }

  @override
  bool operator ==(Object other) =>
      other is FaceImage &&
      other._hash == _hash &&
      other.scale == scale &&
      (identical(other.bytes, bytes) || listEquals(other.bytes, bytes));

  @override
  int get hashCode => Object.hash(_hash, scale);
}
