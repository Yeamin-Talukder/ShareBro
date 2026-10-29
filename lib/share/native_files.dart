import 'package:flutter/services.dart';

/// Android helpers for files that aren't photos: saving into
/// Download/ShareBro and opening them in another app.
class NativeFiles {
  static const _channel = MethodChannel('photo_organizer/files');

  /// Copies [path] into Download/ShareBro[/dir] as [name]; returns where
  /// it landed (a content:// URI, or a path on Android 9).
  static Future<String?> saveToDownloads(String path, String name, String mime, {String? dir}) =>
      _channel.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mime, 'dir': dir});

  /// Opens a content:// URI or file path with whatever app handles [mime].
  static Future<bool> open(String uri, {String? mime}) async {
    try {
      return await _channel.invokeMethod<bool>('open', {'uri': uri, 'mime': mime}) ?? false;
    } on PlatformException {
      return false;
    }
  }
}
