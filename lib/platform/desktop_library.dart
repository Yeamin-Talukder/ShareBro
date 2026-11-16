import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    try {
      head = await raf.read(256 * 1024);
    } finally {
      await raf.close();
    }
    final decoder = img.findDecoderForData(head);
    final info = decoder?.startDecode(head);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    var rotation = 0;
    if (decoder is img.JpegDecoder) {
      final o = img.decodeJpgExif(head)?.imageIfd.orientation ?? 1;
      rotation = switch (o) { 3 || 4 => 180, 5 || 6 => 90, 7 || 8 => 270, _ => 0 };
    }
    return (width: info.width, height: info.height, rotation: rotation);
  } catch (_) {
    return null;
  }
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
