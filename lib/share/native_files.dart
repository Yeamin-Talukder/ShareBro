import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/device.dart';

/// Helpers for files that aren't photos: saving into Download/ShareBro and
/// opening them (or a web link) in another app. Android goes through
/// FilesChannel.kt and iOS through FilesChannel in AppDelegate.swift;
/// desktop uses the Downloads folder and the shell.
class NativeFiles {
  static const _channel = MethodChannel('photo_organizer/files');

  /// Copies [path] into Download/ShareBro[/dir] as [name]; returns where
  /// it landed (a content:// URI, or a path on Android 9, iOS and desktop).
  /// iOS has no shared Downloads: files go into the app's Documents folder,
  /// which the Files app shows as On My iPhone › ShareBro.
  static Future<String?> saveToDownloads(
    String path,
    String name,
    String mime, {
    String? dir,
  }) async {
    if (Device.desktop) {
      final downloads = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
      return _saveInto(p.join(downloads.path, 'ShareBro'), path, name, dir);
    }
    if (Device.ios) return _saveInto((await getApplicationDocumentsDirectory()).path, path, name, dir);
    return _channel.invokeMethod<String>('saveToDownloads', {
      'path': path,
      'name': name,
      'mime': mime,
      'dir': dir,
    });
  }

  static int? _sdk;

  /// The Android API level (28 = Android 9, 33 = Android 13); 0 elsewhere.
  static Future<int> androidSdk() async {
    if (!Device.android) return 0;
    return _sdk ??= await _channel.invokeMethod<int>('sdk') ?? 0;
  }

  /// Opens a content:// URI, file path or web link with whatever app
  /// handles it ([mime] helps Android pick).
  static Future<bool> open(String uri, {String? mime}) async {
    if (Device.desktop) return _openOnDesktop(uri);
    try {
      return await _channel.invokeMethod<bool>('open', {
            'uri': uri,
            'mime': mime,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Copies [path] into [root][/dir] as [name], never over an existing file.
  static Future<String?> _saveInto(
    String root,
    String path,
    String name,
    String? dir,
  ) async {
    final folder = Directory(
      p.joinAll([
        root,
        if (dir != null && dir.isNotEmpty) ...p.split(dir),
      ]),
    );
    await folder.create(recursive: true);
    // Never overwrite: "photo.jpg", then "photo (2).jpg", …
    final base = p.basenameWithoutExtension(name), ext = p.extension(name);
    var target = File(p.join(folder.path, name));
    for (var n = 2; await target.exists(); n++) {
      target = File(p.join(folder.path, '$base ($n)$ext'));
    }
    await File(path).copy(target.path);
    return target.path;
  }

  static Future<bool> _openOnDesktop(String uri) async {
    try {
      if (Platform.isWindows) {
        // Explorer opens files with their default app and links in the
        // browser. It reports exit code 1 even when it worked.
        await Process.run('explorer', [uri]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [uri]);
      } else {
        await Process.run('xdg-open', [uri]);
      }
      return true;
    } on ProcessException {
      return false;
    }
  }
}
