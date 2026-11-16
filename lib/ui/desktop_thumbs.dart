import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Desktop thumbnails, where there's no phone photo library to ask: the
/// photo file is decoded by the engine (native speed, EXIF rotation
/// applied, shrunk while decoding) and small copies are kept on disk so
/// grids open instantly next time.

/// Copies up to this size (the grids) are cached on disk.
const _cacheUpTo = 512;

/// Full-size photo decodes at once; each can take a few hundred MB.
const _parallel = 4;

int _running = 0;
final _waiting = <Completer<void>>[];

Future<T> _limited<T>(Future<T> Function() work) async {
  if (_running >= _parallel) {
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }
  _running++;
  try {
    return await work();
  } finally {
    _running--;
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
  }
}

Directory? _cacheDir;

Future<Directory> _cache() async =>
    _cacheDir ??= await Directory(p.join((await getApplicationSupportDirectory()).path, 'thumbs')).create(recursive: true);

/// A JPEG of the photo at [path], [size] px on its long side (or, with
/// [cover], its short side, for square tiles), never bigger than the photo.
/// Null if the file can't be read as a picture.
Future<Uint8List?> desktopThumbJpeg(String path, int size, {bool cover = false, int quality = 80}) async {
  final file = File(path);
  final FileStat stat;
  try {
    stat = await file.stat();
  } catch (_) {
    return null;
  }
  if (stat.type == FileSystemEntityType.notFound) return null;
  File? cached;
  if (size <= _cacheUpTo) {
    final key = md5.convert(utf8.encode('$path|${stat.modified.millisecondsSinceEpoch}|${stat.size}|$size|$cover'));
    cached = File(p.join((await _cache()).path, '$key.jpg'));
    try {
      if (await cached.exists()) return await cached.readAsBytes();
    } catch (_) {}
  }
  final jpeg = await _limited(() => _render(file, size, cover, quality));
  if (jpeg != null && cached != null) {
    try {
      await cached.writeAsBytes(jpeg);
    } catch (_) {
      // A full or read-only disk only costs speed.
    }
  }
  return jpeg;
}

/// The photo's size as shown (upright), or null if it can't be read.
Future<ui.Size?> desktopPhotoSize(String path) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await File(path).readAsBytes());
    ui.Size? size;
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      size = ui.Size(w.toDouble(), h.toDouble());
      return const ui.TargetImageSize(width: 1, height: 1);
    });
    codec.dispose();
    return size;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _render(File file, int size, bool cover, int quality) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    final codec = await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      final side = cover ? math.min(w, h) : math.max(w, h);
      final scale = math.min(1.0, size / side);
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
      return await Isolate.run(() => img.encodeJpg(
            img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4),
            quality: quality,
          ));
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
