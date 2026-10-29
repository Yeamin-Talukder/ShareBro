import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../share/prepare.dart';

/// An app on this phone that can be sent like a file.
class InstalledApp {
  InstalledApp({
    required this.package,
    required this.name,
    required this.version,
    required this.files,
    required this.size,
    required this.system,
  });

  factory InstalledApp.fromMap(Map<Object?, Object?> m) => InstalledApp(
        package: m['package']! as String,
        name: m['name'] as String? ?? m['package']! as String,
        version: m['version'] as String? ?? '',
        files: [for (final f in (m['files'] as List? ?? const [])) f as String],
        size: (m['size'] as num?)?.toInt() ?? 0,
        system: m['system'] == true,
      );

  final String package;
  final String name;
  final String version;

  /// The base APK, then any split APKs (apps installed from app bundles).
  final List<String> files;
  final int size;
  final bool system;

  /// Installed from an app bundle: needs all its parts to install.
  bool get isSplit => files.length > 1;

  /// "WhatsApp 2.24.1", safe as a file name.
  String get label {
    final raw = version.isEmpty ? name : '$name $version';
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  }

  /// What gets sent: one `App version.apk`, or for bundle-installed
  /// apps a folder with every part (installable with an app like SAI).
  List<SendItem> toSendItems() => isSplit
      ? [for (final f in files) SendItem.file(f, name: '$label/${p.basename(f)}')]
      : [SendItem.file(files.first, name: '$label.apk')];
}

class Apps {
  static const _channel = MethodChannel('photo_organizer/apps');

  static Future<List<InstalledApp>> list({bool system = false}) async {
    try {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>('list', {'system': system}) ?? const [];
      return [for (final r in rows) InstalledApp.fromMap(r)];
    } on MissingPluginException {
      return const [];
    }
  }

  static final _icons = <String, Future<Uint8List?>>{};

  /// The app's icon as PNG bytes (cached).
  static Future<Uint8List?> icon(String package, {int size = 96}) => _icons.putIfAbsent(package, () async {
        try {
          return await _channel.invokeMethod<Uint8List>('icon', {'package': package, 'size': size});
        } on PlatformException {
          return null;
        }
      });
}
