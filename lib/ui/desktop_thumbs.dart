import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../platform/worker_pool.dart';
import '../platform/app_dirs.dart';

/// Desktop thumbnails, where there's no phone photo library to ask: the
/// photo file is decoded by the engine straight at the size asked for
/// (native speed, EXIF rotation applied, never at full resolution unless
/// that's what's wanted), and small copies are kept on disk so grids and
/// the viewer open instantly next time.
///
/// What's on screen never waits for a JPEG encode: the decoded pixels go
/// to the screen first, and the disk copy is written afterwards in the
/// background.

/// Copies up to this size (the grids) are cached on disk.
const _cacheUpTo = 512;

/// Also cached: the viewer's usual size steps (FastThumb steps for a
/// 1080p–1440p window), so reopening a photo is instant too.
const _cachedViewSizes = {1024, 1600};

/// The thumbs folder is trimmed back to [_cacheKeep] when it passes this.
const _cacheMax = 500 * 1024 * 1024;
const _cacheKeep = 400 * 1024 * 1024;

/// Originals decoded at once; each can take a lot of memory while decoding.
const _parallel = 4;

/// Background disk-cache writes at once, and how many may wait; past that
/// the oldest waiting ones are dropped (the copy is simply made again next
/// time it's needed).
const _encodesRunning = 2;
const _encodesWaiting = 12;

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
    _cacheDir ??= await Directory(p.join((await appDataDir()).path, 'thumbs')).create(recursive: true);

bool _cacheable(int size) => size <= _cacheUpTo || _cachedViewSizes.contains(size);

/// Where the disk copy of [path] at [size] lives (it may not exist yet), or
/// null if this size isn't cached.
Future<File?> _cacheFile(String path, FileStat stat, int size, bool cover) async {
  if (!_cacheable(size)) return null;
  final key = md5.convert(utf8.encode('$path|${stat.modified.millisecondsSinceEpoch}|${stat.size}|$size|$cover'));
  return File(p.join((await _cache()).path, '$key.jpg'));
}

Future<FileStat?> _stat(String path) async {
  try {
    final stat = await File(path).stat();
    return stat.type == FileSystemEntityType.notFound ? null : stat;
  } catch (_) {
    return null;
  }
}

/// The photo at [path] as an image codec, [size] px on its long side (or,
/// with [cover], its short side, for square tiles), never bigger than the
/// photo. Null if the file can't be read as a picture.
///
/// A cached copy is used when there is one; otherwise the original is
/// decoded at that size and a cached copy is written in the background.
Future<ui.Codec?> desktopThumbCodec(String path, int size, {bool cover = false, int quality = 80}) async {
  final stat = await _stat(path);
  if (stat == null) return null;
  final cached = await _cacheFile(path, stat, size, cover);
  if (cached != null) {
    try {
      if (await cached.exists()) {
        return await ui.instantiateImageCodecFromBuffer(await ui.ImmutableBuffer.fromFilePath(cached.path));
      }
    } catch (_) {
      // A broken cached copy: decode the original instead.
    }
  }
  return _limited(() async {
    final codec = await _decodeAtSize(path, size, cover);
    if (codec == null || cached == null) return codec;
    // Take the one frame, keep its pixels for the disk copy, and show
    // them straight away.
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final w = image.width, h = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return null;
      final rgba = data.buffer.asUint8List();
      _writeLater(cached.path, rgba, w, h, quality);
      final descriptor = ui.ImageDescriptor.raw(
        await ui.ImmutableBuffer.fromUint8List(rgba),
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      return await descriptor.instantiateCodec();
    } catch (_) {
      return null;
    } finally {
      codec.dispose();
    }
  });
}

/// A JPEG of the photo at [path], [size] px on its long side (or, with
/// [cover], its short side), never bigger than the photo. Null if the file
/// can't be read as a picture. For sending and the web gallery, which need
/// the bytes themselves.
Future<Uint8List?> desktopThumbJpeg(String path, int size, {bool cover = false, int quality = 80}) async {
  final stat = await _stat(path);
  if (stat == null) return null;
  final cached = await _cacheFile(path, stat, size, cover);
  if (cached != null) {
    try {
      if (await cached.exists()) return await cached.readAsBytes();
    } catch (_) {}
  }
  final pixels = await _limited(() => _pixelsAtSize(path, size, cover));
  if (pixels == null) return null;
  final (rgba, w, h) = pixels;
  final out = cached?.path;
  return WorkerPool.shared.run(_encodeAndSaveJob(rgba, w, h, quality, out));
}

/// The photo's size as shown (upright), or null if it can't be read. Reads
/// only the start of the file: the header and EXIF are all it needs.
Future<ui.Size?> desktopPhotoSize(String path) async {
  try {
    final raf = await File(path).open();
    final Uint8List head;
    try {
      head = await raf.read(256 * 1024);
    } finally {
      await raf.close();
    }
    final decoder = img.findDecoderForData(head);
    final info = decoder?.startDecode(head);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    var turned = false;
    if (decoder is img.JpegDecoder) {
      final o = img.decodeJpgExif(head)?.imageIfd.orientation ?? 1;
      turned = o >= 5 && o <= 8;
    }
    return turned
        ? ui.Size(info.height.toDouble(), info.width.toDouble())
        : ui.Size(info.width.toDouble(), info.height.toDouble());
  } catch (_) {
    return null;
  }
}

/// The original decoded by the engine at [size], read straight from disk
/// (not copied into Dart memory first).
Future<ui.Codec?> _decodeAtSize(String path, int size, bool cover) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    return await ui.instantiateImageCodecWithSize(buffer, getTargetSize: (w, h) {
      final side = cover ? math.min(w, h) : math.max(w, h);
      final scale = math.min(1.0, size / side);
      return ui.TargetImageSize(width: math.max(1, (w * scale).round()), height: math.max(1, (h * scale).round()));
    });
  } catch (_) {
    return null;
  }
}

/// The photo's pixels (RGBA) at [size], with its width and height.
Future<(Uint8List, int, int)?> _pixelsAtSize(String path, int size, bool cover) async {
  final codec = await _decodeAtSize(path, size, cover);
  if (codec == null) return null;
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final w = image.width, h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data == null ? null : (data.buffer.asUint8List(), w, h);
  } catch (_) {
    return null;
  } finally {
    codec.dispose();
  }
}

int _encodesNow = 0;
final _encodeQueue = <(String, Uint8List, int, int, int)>[];

/// Writes the disk copy in the background, a couple at a time, newest
/// first (the photos just scrolled to).
void _writeLater(String out, Uint8List rgba, int w, int h, int quality) {
  if (_encodeQueue.length >= _encodesWaiting) _encodeQueue.removeAt(0);
  _encodeQueue.add((out, rgba, w, h, quality));
  _pump();
}

void _pump() {
  while (_encodesNow < _encodesRunning && _encodeQueue.isNotEmpty) {
    final (out, rgba, w, h, quality) = _encodeQueue.removeLast();
    _encodesNow++;
    WorkerPool.shared.run(_encodeAndSaveJob(rgba, w, h, quality, out)).catchError((Object _) => Uint8List(0)).whenComplete(() {
      _encodesNow--;
      _written++;
      _maybeTrim();
      _pump();
    });
  }
}

Uint8List _encode(Uint8List rgba, int w, int h, int quality) =>
    img.encodeJpg(img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4), quality: quality);

/// Writes [jpeg] to [out] through a temporary name, so a half-written copy
/// is never read back.
void _save(String out, Uint8List jpeg) {
  try {
    final tmp = File('$out.part');
    tmp.writeAsBytesSync(jpeg);
    tmp.renameSync(out);
  } catch (_) {
    // A full or read-only disk only costs speed.
  }
}

int _written = 0;
bool _trimming = false;

/// Every few hundred new copies, checks the folder's size and deletes the
/// oldest copies once it passes [_cacheMax].
void _maybeTrim() {
  if (_trimming || _written % 300 != 1) return;
  final dir = _cacheDir?.path;
  if (dir == null) return;
  _trimming = true;
  WorkerPool.shared.run(() => _trim(dir)).catchError((Object _) {}).whenComplete(() => _trimming = false);
}

void _trim(String dir) {
  final files = <(File, int, DateTime)>[];
  var total = 0;
  for (final e in Directory(dir).listSync(followLinks: false)) {
    if (e is! File) continue;
    try {
      final s = e.statSync();
      files.add((e, s.size, s.accessed.isAfter(s.modified) ? s.accessed : s.modified));
      total += s.size;
    } catch (_) {}
  }
  if (total <= _cacheMax) return;
  files.sort((a, b) => a.$3.compareTo(b.$3));
  for (final (f, size, _) in files) {
    if (total <= _cacheKeep) break;
    try {
      f.deleteSync();
      total -= size;
    } catch (_) {}
  }
}

/// A worker-pool job that encodes [rgba] as JPEG and, with [out], saves it
/// there. Built outside any closure-heavy function so it captures only
/// these plain values.
Uint8List Function() _encodeAndSaveJob(Uint8List rgba, int w, int h, int quality, String? out) => () {
      final jpeg = _encode(rgba, w, h, quality);
      if (out != null) _save(out, jpeg);
      return jpeg;
    };
