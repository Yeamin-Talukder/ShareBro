import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../face/tags.dart' show differenceHash;
import '../platform/device.dart';
import '../ui/fast_thumb.dart' show FastThumb;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../data/db.dart' show FileKey;
import '../platform/worker_pool.dart';

/// One photo to scan: from the phone's photo library ([PhoneScanItem]) or,
/// on desktop, a file on disk ([DesktopScanItem], whose id is its path).
abstract class ScanItem {
  /// The photo with this id, if it still exists.
  static Future<ScanItem?> byId(String id) async {
    if (Device.photoLibrary) {
      final asset = await AssetEntity.fromId(id);
      return asset == null ? null : PhoneScanItem(asset);
    }
    return await File(id).exists() ? DesktopScanItem(id) : null;
  }

  String get id;

  /// When it was taken (on desktop: the EXIF date, else the file's date).
  DateTime get takenAt;

  /// Its size as shown (upright). On desktop, known after [scanJpeg].
  ui.Size get size;

  /// The folder it's in and its file name, for categories like
  /// "WhatsApp" or "Screenshots".
  String get folder;
  String get title;

  /// A downscaled, upright JPEG (long side [longSide]) to look for faces
  /// in. The original photo is never touched.
  Future<Uint8List?> scanJpeg(int longSide);

  /// Where it was taken, if it says.
  Future<LatLng?> location();

  /// Duplicate fingerprint from a tiny thumbnail (see [differenceHash]).
  Future<int?> hash();
}

/// A photo in the phone's library.
class PhoneScanItem implements ScanItem {
  PhoneScanItem(this.asset);

  final AssetEntity asset;

  @override
  String get id => asset.id;

  @override
  DateTime get takenAt => asset.createDateTime;

  @override
  ui.Size get size => asset.orientatedSize;

  @override
  String get folder => asset.relativePath ?? '';

  @override
  String get title => asset.title ?? '';

  @override
  Future<Uint8List?> scanJpeg(int longSide) =>
      asset.thumbnailDataWithSize(_sizeFor(asset, longSide), quality: 90);

  /// The scan copy's size: the long side [longSide], same shape as the photo.
  static ThumbnailSize _sizeFor(AssetEntity asset, int longSide) {
    final w = asset.width, h = asset.height;
    return (w <= 0 || h <= 0)
        ? ThumbnailSize.square(longSide)
        : w >= h
            ? ThumbnailSize(longSide, longSide * h ~/ w)
            : ThumbnailSize(longSide * w ~/ h, longSide);
  }

  @override
  Future<LatLng?> location() => asset.latlngAsync().then<LatLng?>((v) => v, onError: (Object _) => null);

  /// Uses Android's stored thumbnail when it can: the photo library plugin
  /// would decode the whole photo again just for these 72 pixels.
  @override
  Future<int?> hash() async {
    final stored = await FastThumb.pixels(asset.id, 48, video: asset.type == AssetType.video);
    if (stored != null) {
      return _hashOf(img.Image.fromBytes(
          width: stored.width, height: stored.height, bytes: stored.rgba.buffer, numChannels: 4));
    }
    final bytes = await asset.thumbnailDataWithSize(const ThumbnailSize.square(48), quality: 80);
    if (bytes == null) return null;
    final small = img.decodeImage(bytes);
    return small == null ? null : _hashOf(small);
  }
}

int _hashOf(img.Image small) {
  final tiny = img.copyResize(small, width: 9, height: 8, interpolation: img.Interpolation.average);
  return differenceHash([
    for (var y = 0; y < 8; y++)
      for (var x = 0; x < 9; x++) tiny.getPixel(x, y).luminance.toInt(),
  ]);
}

/// A photo file on a desktop computer. Its id is its full path.
class DesktopScanItem implements ScanItem {
  DesktopScanItem(this.path);

  final String path;

  /// Read from the file's EXIF the first time it's needed.
  _Exif? _exif;
  ui.Size _size = ui.Size.zero;

  /// The small copy [scanJpeg] made, reused for [hash].
  img.Image? _small;

  /// What the file was when it was looked at (see [FileKey]); saved with
  /// the scan.
  FileKey? fileKey;

  @override
  String get id => path;

  @override
  DateTime get takenAt => _exif?.takenAt ?? _modified() ?? DateTime.now();

  DateTime? _modified() {
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  @override
  ui.Size get size => _size;

  @override
  String get folder => p.dirname(path);

  @override
  String get title => p.basename(path);

  Future<_Exif?>? _reading;

  /// Reads the EXIF block (date taken, GPS) on a background worker. Call
  /// before [takenAt].
  Future<void> readMeta() async {
    if (_exif != null) return;
    _exif = await (_reading ??= WorkerPool.shared.run(_exifJob(path)));
  }

  /// The photo decoded straight from its file to upright RGBA pixels, its
  /// long side at least [atLeast] (or the whole photo, if smaller). Shrinks
  /// by a half, a quarter or an eighth only: JPEG decoders do those while
  /// decoding, almost for free, where any other size means decoding bigger
  /// and resizing. A 12 MP photo (4000 px) comes out at 1000 px, a 24 MP one
  /// at 1500. Sets [size] to the full photo's upright size. Null if it can't
  /// be read.
  Future<(Uint8List, int, int)?> decodePixels({int atLeast = 1000}) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      _size = ui.Size(w.toDouble(), h.toDouble());
      final long = math.max(w, h);
      var shrink = 1;
      while (shrink < 8 && (long / (shrink * 2)).ceil() >= atLeast) {
        shrink *= 2;
      }
      return ui.TargetImageSize(width: math.max(1, (w / shrink).ceil()), height: math.max(1, (h / shrink).ceil()));
    });
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width, h = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return null;
      return (data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), w, h);
    } finally {
      codec.dispose();
    }
  }

  /// The file's [FileKey]: its size and date from the file system, and a
  /// hash of its first and last 64 KB (enough to tell photos apart; far
  /// cheaper than reading the whole file).
  static Future<FileKey?> keyOf(String path) => WorkerPool.shared.run(() {
        try {
          final f = File(path);
          final stat = f.statSync();
          final raf = f.openSync();
          try {
            const part = 64 * 1024;
            final head = raf.readSync(part);
            final len = stat.size;
            List<int> tail = const [];
            if (len > part) {
              raf.setPositionSync(math.max(part, len - part));
              tail = raf.readSync(part);
            }
            final digest = md5.convert([...utf8.encode('$len|'), ...head, ...tail]);
            return FileKey(size: len, modified: stat.modified.millisecondsSinceEpoch, content: digest.toString());
          } finally {
            raf.closeSync();
          }
        } catch (_) {
          return null;
        }
      });

  @override
  Future<Uint8List?> scanJpeg(int longSide) async {
    await readMeta();
    final bytes = await File(path).readAsBytes();
    // The engine's decoder: native speed, applies the EXIF rotation, and
    // shrinks while decoding.
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      _size = ui.Size(w.toDouble(), h.toDouble());
      final scale = math.min(1.0, longSide / math.max(w, h));
      return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
    });
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width, h = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return null;
      final rgba = data.buffer.asUint8List();
      final (jpeg, small) = await WorkerPool.shared.run(_encodeJob(rgba, w, h));
      _small = small;
      return jpeg;
    } finally {
      codec.dispose();
    }
  }

  @override
  Future<LatLng?> location() async {
    await readMeta();
    final e = _exif;
    if (e == null || e.lat == null || e.lng == null) return null;
    return LatLng(latitude: e.lat!, longitude: e.lng!);
  }

  @override
  Future<int?> hash() async {
    final small = _small;
    if (small != null) return _hashOf(small);
    final jpeg = await scanJpeg(96);
    return _small == null || jpeg == null ? null : _hashOf(_small!);
  }
}

/// The few EXIF facts a scan needs.
class _Exif {
  _Exif(this.takenAt, this.lat, this.lng);

  final DateTime? takenAt;
  final double? lat, lng;

  static _Exif? read(String path) {
    try {
      final file = File(path).openSync();
      // EXIF lives at the start of a JPEG; no need to read a 10 MB photo.
      final head = file.readSync(256 * 1024);
      file.closeSync();
      final exif = img.decodeJpgExif(head);
      if (exif == null) return null;
      final taken = _date(exif.exifIfd[0x9003]?.toString() ?? exif.imageIfd[0x0132]?.toString());
      final gps = exif.gpsIfd;
      double? coord(int tag, int refTag, String negative) {
        final v = gps[tag];
        if (v == null) return null;
        final value = v.toDouble(0) + v.toDouble(1) / 60 + v.toDouble(2) / 3600;
        return gps[refTag]?.toString().trim().toUpperCase() == negative ? -value : value;
      }

      return _Exif(taken, coord(0x0002, 0x0001, 'S'), coord(0x0004, 0x0003, 'W'));
    } catch (_) {
      return null;
    }
  }

  /// "2026:10:17 09:52:55" (EXIF's own format), as local time.
  static DateTime? _date(String? s) {
    if (s == null || s.length < 19) return null;
    return DateTime.tryParse('${s.substring(0, 10).replaceAll(':', '-')}T${s.substring(11, 19)}');
  }
}

// Jobs for the worker pool are built here, outside any method, so they
// capture only the plain values passed in (never the photo object, which
// holds things that can't be sent to another isolate).

_Exif? Function() _exifJob(String path) => () => _Exif.read(path);

(Uint8List, img.Image) Function() _encodeJob(Uint8List rgba, int w, int h) => () {
      final im = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4);
      return (img.encodeJpg(im, quality: 90), img.copyResize(im, width: 48, height: 48));
    };
