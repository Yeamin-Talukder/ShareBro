import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../ui/widgets.dart' show AssetThumb;
import 'protocol.dart' show mimeFor;

/// What to send: the untouched original, the original without location and
/// camera details, or a smaller copy that's quicker to send.
enum SendQuality { original, noLocation, smaller }

/// Longest side of "smaller" photos.
const _smallSize = 2048;

/// A photo ready to go: its name, exact size, and how to read its bytes.
class PreparedFile {
  PreparedFile({
    required this.assetId,
    required this.fileName,
    required this.size,
    required this.mime,
    required this.file,
    this.modified,
  });

  final String assetId;
  final String fileName;
  final int size;
  final String mime;
  final File file;
  final DateTime? modified;

  /// The message itself, for text sent as a `.txt` (LocalSend shows it
  /// as a message instead of a file).
  String? preview;

  /// A gallery photo or video (not a picked file or a message).
  bool get isAsset => !assetId.contains(':');

  Stream<List<int>> open() => file.openRead();
}

/// Something to send: a gallery item, any file on the phone, or a message.
class SendItem {
  const SendItem.asset(String id)
      : assetId = id,
        path = null,
        text = null,
        name = null;

  /// [name] may contain folders ("Trip/notes.txt") when a folder was picked.
  const SendItem.file(String this.path, {this.name})
      : assetId = null,
        text = null;
  const SendItem.text(String this.text)
      : assetId = null,
        path = null,
        name = null;

  final String? assetId;
  final String? path;
  final String? text;
  final String? name;

  bool get isAsset => assetId != null;

  /// Everything inside [dir], keeping the folder layout in the names.
  static Future<List<SendItem>> folder(String dir) async {
    final root = Directory(dir);
    final base = p.basename(dir);
    return [
      await for (final e in root.list(recursive: true, followLinks: false))
        if (e is File) SendItem.file(e.path, name: p.posix.joinAll([base, ...p.split(p.relative(e.path, from: dir))])),
    ];
  }
}

/// Prepares any mix of [items]; gallery items follow [quality].
Future<List<PreparedFile>> prepareItems(
  List<SendItem> items,
  SendQuality quality,
  Directory tmp, {
  void Function(int done, int total)? onProgress,
}) async {
  final out = <PreparedFile>[];
  final used = <String>{};
  void add(PreparedFile f) {
    var name = f.fileName;
    for (var n = 2; used.contains(name.toLowerCase()); n++) {
      name = p.posix.join(p.posix.dirname(f.fileName) == '.' ? '' : p.posix.dirname(f.fileName),
          '${p.basenameWithoutExtension(f.fileName)} ($n)${p.extension(f.fileName)}');
    }
    used.add(name.toLowerCase());
    out.add(PreparedFile(
      assetId: f.assetId,
      fileName: name,
      size: f.size,
      mime: f.mime,
      file: f.file,
      modified: f.modified,
    )..preview = f.preview);
  }

  for (var i = 0; i < items.length; i++) {
    onProgress?.call(i, items.length);
    final item = items[i];
    if (item.assetId != null) {
      final asset = await AssetThumb.entity(item.assetId!);
      final f = asset == null ? null : await _prepareOne(asset, quality, tmp);
      if (f != null) add(f);
    } else if (item.path != null) {
      final file = File(item.path!);
      if (!await file.exists()) continue;
      final name = item.name ?? p.basename(file.path);
      add(PreparedFile(
        assetId: 'file:${file.path}',
        fileName: name,
        size: await file.length(),
        mime: mimeFor(name),
        file: file,
        modified: await file.lastModified(),
      ));
    } else if (item.text != null) {
      final f = File(p.join(tmp.path, 'message_$i.txt'));
      await f.writeAsString(item.text!, flush: true);
      add(PreparedFile(
        assetId: 'text:$i',
        fileName: 'message.txt',
        size: await f.length(),
        mime: 'text/plain',
        file: f,
        modified: DateTime.now(),
      )..preview = item.text);
    }
  }
  onProgress?.call(items.length, items.length);
  return out;
}

/// Prepares gallery [ids] for sending. Originals are read in place; edited
/// copies go to [tmp] (delete it afterwards).
Future<List<PreparedFile>> prepareFiles(
  List<String> ids,
  SendQuality quality,
  Directory tmp, {
  void Function(int done, int total)? onProgress,
}) =>
    prepareItems([for (final id in ids) SendItem.asset(id)], quality, tmp, onProgress: onProgress);

Future<PreparedFile?> _prepareOne(AssetEntity asset, SendQuality quality, Directory tmp) async {
  final original = await asset.file;
  if (original == null) return null;
  final title = (asset.title?.isNotEmpty ?? false) ? asset.title! : p.basename(original.path);
  final ext = p.extension(title).toLowerCase();
  final isJpeg = ext == '.jpg' || ext == '.jpeg';

  Future<PreparedFile> fromBytes(Uint8List bytes, String name) async {
    final f = File(p.join(tmp.path, '${asset.id.hashCode}_$name'));
    await f.writeAsBytes(bytes, flush: true);
    return PreparedFile(
      assetId: asset.id,
      fileName: name,
      size: bytes.length,
      mime: 'image/jpeg',
      file: f,
      modified: asset.createDateTime,
    );
  }

  String asJpg(String name) => '${p.basenameWithoutExtension(name)}.jpg';

  // Videos always go as they are (resizing them needs a transcoder).
  switch (asset.type == AssetType.video ? SendQuality.original : quality) {
    case SendQuality.original:
      return PreparedFile(
        assetId: asset.id,
        fileName: title,
        size: await original.length(),
        mime: asset.mimeType ?? _mime(ext),
        file: original,
        modified: asset.createDateTime,
      );
    case SendQuality.noLocation:
      if (isJpeg) {
        final bytes = await original.readAsBytes();
        // Lossless when the pixels are already upright; otherwise the
        // rotation lives in the metadata we're removing, so re-save upright.
        if (exifOrientation(bytes) <= 1) {
          return fromBytes(stripJpegMetadata(bytes), title);
        }
      } else if (ext == '.png') {
        // PNGs from phones carry no location.
        return _prepareOne(asset, SendQuality.original, tmp);
      }
      final full = await asset.thumbnailDataWithSize(
          ThumbnailSize(asset.orientatedWidth, asset.orientatedHeight),
          quality: 95);
      return full == null ? null : fromBytes(full, asJpg(title));
    case SendQuality.smaller:
      final w = asset.orientatedWidth, h = asset.orientatedHeight;
      final scale = w <= 0 || h <= 0 ? 1.0 : _smallSize / (w > h ? w : h);
      if (scale >= 1) return _prepareOne(asset, SendQuality.noLocation, tmp);
      final small = await asset.thumbnailDataWithSize(
          ThumbnailSize((w * scale).round(), (h * scale).round()),
          quality: 88);
      return small == null ? null : fromBytes(small, asJpg(title));
  }
}

String _mime(String ext) => switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.heic' => 'image/heic',
      '.heif' => 'image/heif',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.mp4' => 'video/mp4',
      '.mov' => 'video/quicktime',
      '.3gp' => 'video/3gpp',
      '.mkv' => 'video/x-matroska',
      '.webm' => 'video/webm',
      _ => 'application/octet-stream',
    };

/// Removes EXIF (location, camera, time), XMP and IPTC blocks from a JPEG
/// without touching the image data.
Uint8List stripJpegMetadata(Uint8List src) {
  if (src.length < 4 || src[0] != 0xFF || src[1] != 0xD8) return src;
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  while (i + 4 <= src.length) {
    if (src[i] != 0xFF) break;
    final marker = src[i + 1];
    // Start of scan: the compressed image follows to the end.
    if (marker == 0xDA) {
      out.add(Uint8List.sublistView(src, i));
      return out.toBytes();
    }
    final len = (src[i + 2] << 8) | src[i + 3];
    final end = i + 2 + len;
    if (end > src.length) break;
    final drop = (marker == 0xE1 && (_startsWith(src, i + 4, 'Exif') || _startsWith(src, i + 4, 'http'))) ||
        marker == 0xED;
    if (!drop) out.add(Uint8List.sublistView(src, i, end));
    i = end;
  }
  // Unusual layout: send it unchanged rather than risk breaking it.
  return src;
}

bool _startsWith(Uint8List b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (b[at + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

/// EXIF orientation of a JPEG (1 = upright), or 0 if there's none.
int exifOrientation(Uint8List b) {
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final marker = b[i + 1];
    final len = (b[i + 2] << 8) | b[i + 3];
    if (marker == 0xDA) return 0;
    if (marker == 0xE1 && _startsWith(b, i + 4, 'Exif')) {
      final tiff = i + 10;
      if (tiff + 8 > b.length) return 0;
      final little = b[tiff] == 0x49;
      int u16(int o) => little ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1];
      int u32(int o) => little
          ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
          : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
      final ifd = tiff + u32(tiff + 4);
      if (ifd + 2 > b.length) return 0;
      final count = u16(ifd);
      for (var e = 0; e < count; e++) {
        final entry = ifd + 2 + e * 12;
        if (entry + 12 > b.length) return 0;
        if (u16(entry) == 0x0112) return u16(entry + 8);
      }
      return 0;
    }
    i += 2 + len;
  }
  return 0;
}
