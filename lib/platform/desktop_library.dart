import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import 'device.dart';

/// The desktop stand-in for the phone's photo library: a photo is a file,
/// its id is the file's full path.
///
/// The screens are built around photo_manager's [AssetEntity]; on desktop
/// they get one made from the file ([desktopEntity]) so the grids, viewer
/// and dates work unchanged. Only its plain fields are filled in: anything
/// that asks the photo library (thumbnails, `file`, `latlngAsync`) isn't
/// available, so use [AssetFile.localFile] and FastThumb instead.

/// When a scanned photo was taken (its EXIF date, from the database). Set
/// by the scan controller; files it doesn't know use their modified date.
Future<DateTime?> Function(String path)? desktopTakenAt;

/// A photo-library entry for the picture file at [path], or null if it's
/// gone or isn't a picture.
Future<AssetEntity?> desktopEntity(String path) async {
  final file = File(path);
  final FileStat stat;
  try {
    stat = await file.stat();
  } catch (_) {
    return null;
  }
  if (stat.type != FileSystemEntityType.file) return null;
  final shape = await _shape(file);
  DateTime? taken;
  try {
    taken = await desktopTakenAt?.call(path);
  } catch (_) {}
  taken ??= stat.modified;
  return AssetEntity(
    id: path,
    typeInt: AssetType.image.index,
    width: shape?.width ?? 0,
    height: shape?.height ?? 0,
    orientation: shape?.rotation ?? 0,
    title: p.basename(path),
    relativePath: p.dirname(path),
    createDateSecond: taken.millisecondsSinceEpoch ~/ 1000,
    modifiedDateSecond: stat.modified.millisecondsSinceEpoch ~/ 1000,
    mimeType: _mime(p.extension(path).toLowerCase()),
  );
}

String _mime(String ext) => switch (ext) {
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.gif' => 'image/gif',
      '.bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };

/// Width and height as stored, and the EXIF turn (0, 90, 180 or 270) that
/// makes it upright. Read from the start of the file only.
Future<({int width, int height, int rotation})?> _shape(File file) async {
  try {
    final raf = await file.open();
    final Uint8List head;
    ({int width, int height})? jpeg;
    try {
      head = await raf.read(256 * 1024);
      // JPEG: find the frame header by walking the file's segments, since
      // it can sit well past the first 256 KB (Pixel portrait photos carry
      // megabytes of depth data before it). Reading only the start once
      // gave sizes like 18761 × 42, and the viewer squashed the photo into
      // a thin line.
      if (head.length > 2 && head[0] == 0xFF && head[1] == 0xD8) jpeg = await _jpegSize(raf);
    } finally {
      await raf.close();
    }
    final decoder = img.findDecoderForData(head);
    var rotation = 0;
    if (decoder is img.JpegDecoder || jpeg != null) {
      final o = img.decodeJpgExif(head)?.imageIfd.orientation ?? 1;
      rotation = switch (o) { 3 || 4 => 180, 5 || 6 => 90, 7 || 8 => 270, _ => 0 };
    }
    if (jpeg != null) return (width: jpeg.width, height: jpeg.height, rotation: rotation);
    final info = decoder?.startDecode(head);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (width: info.width, height: info.height, rotation: rotation);
  } catch (_) {
    return null;
  }
}

/// A JPEG's width and height from its frame (SOF) header, found by jumping
/// from segment to segment without reading what's in them.
Future<({int width, int height})?> _jpegSize(RandomAccessFile raf) async {
  final length = await raf.length();
  var pos = 2;
  for (var guard = 0; guard < 4096 && pos + 4 <= length; guard++) {
    await raf.setPosition(pos);
    final h = await raf.read(4);
    if (h.length < 4 || h[0] != 0xFF) return null;
    final marker = h[1];
    // Fill bytes, and markers that have no length.
    if (marker == 0xFF) {
      pos += 1;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      pos += 2;
      continue;
    }
    // The image data or the end came before any frame header.
    if (marker == 0xDA || marker == 0xD9) return null;
    final size = (h[2] << 8) | h[3];
    if (size < 2) return null;
    final frame = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
    if (frame) {
      final b = await raf.read(5); // precision, height, width
      if (b.length < 5) return null;
      final height = (b[1] << 8) | b[2], width = (b[3] << 8) | b[4];
      return width > 0 && height > 0 ? (width: width, height: height) : null;
    }
    pos += 2 + size;
  }
  return null;
}

extension AssetFile on AssetEntity {
  /// The photo's file: on desktop, the path it is; on a phone, from the
  /// photo library.
  Future<File?> get localFile => Device.desktop ? Future.value(File(id)) : file;
}

/// Opens File Explorer (Finder, the file manager) with the photo selected.
Future<void> revealInFolder(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [p.dirname(path)]);
    }
  } on ProcessException {
    // No file manager: nothing to show.
  }
}

/// Moves the files to the Recycle Bin (the Trash), where they can be
/// restored. Returns the paths that are gone.
Future<Set<String>> moveToRecycleBin(List<String> paths) async {
  if (paths.isEmpty) return {};
  try {
    if (Platform.isWindows) {
      // .NET's FileSystem.DeleteFile can send to the Recycle Bin. The paths
      // go through a file, never the command line, so no name can be read
      // as a command.
      final list = File(p.join(Directory.systemTemp.path, 'sharebro_trash_${DateTime.now().microsecondsSinceEpoch}.txt'));
      await list.writeAsString(paths.join('\n'), flush: true);
      try {
        const script = r'''
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($f in [IO.File]::ReadAllLines($env:SHAREBRO_TRASH_LIST, [Text.Encoding]::UTF8)) {
  if ($f -and [IO.File]::Exists($f)) {
    try {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } catch {}
  }
}''';
        await Process.run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
          environment: {'SHAREBRO_TRASH_LIST': list.path},
        );
      } finally {
        try {
          await list.delete();
        } catch (_) {}
      }
    } else if (Platform.isMacOS && await _macTrash(paths)) {
      // Done natively (MacFilesChannel in MainFlutterWindow.swift).
    } else if (Platform.isMacOS) {
      for (final f in paths) {
        await Process.run('osascript', [
          '-e',
          'on run argv',
          '-e',
          'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)',
          '-e',
          'end run',
          f,
        ]);
      }
    } else {
      await Process.run('gio', ['trash', '--', ...paths]);
    }
  } on ProcessException {
    // No way to reach the bin: nothing was moved.
  }
  return {
    for (final f in paths)
      if (!await File(f).exists()) f,
  };
}

/// Sends [paths] to the Trash through FileManager (no "control Finder"
/// prompt). False if the native side isn't there, so the caller falls back
/// to asking Finder.
Future<bool> _macTrash(List<String> paths) async {
  try {
    await const MethodChannel('photo_organizer/mac_files').invokeMethod<List<Object?>>('trash', {'paths': paths});
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
