import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Picture files a desktop scan picks up (what the engine's decoder reads
/// on every desktop: no HEIC or RAW yet).
const desktopPhotoExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'};

/// The trip key for a scanned desktop folder (phones use album ids).
String desktopFolderKey(String folder) => 'desktop:${p.normalize(folder)}';

/// The folder behind a [desktopFolderKey], or null for other trips.
String? desktopFolderOf(String key) => key.startsWith('desktop:') ? key.substring(8) : null;

/// Every photo under [folder], newest first (by file date). Hidden folders
/// and ones that can't be read are skipped. Runs off the main isolate.
Future<List<String>> listPhotoFiles(String folder) => Isolate.run(() {
      final found = <(String, DateTime)>[];
      void walk(Directory dir) {
        List<FileSystemEntity> entries;
        try {
          entries = dir.listSync(followLinks: false);
        } catch (_) {
          return;
        }
        for (final e in entries) {
          final name = p.basename(e.path);
          if (name.startsWith('.') || name.startsWith(r'$')) continue;
          if (e is Directory) {
            walk(e);
          } else if (e is File && desktopPhotoExtensions.contains(p.extension(name).toLowerCase())) {
            try {
              found.add((e.path, e.lastModifiedSync()));
            } catch (_) {}
          }
        }
      }

      walk(Directory(folder));
      found.sort((a, b) => b.$2.compareTo(a.$2));
      return [for (final (path, _) in found) path];
    });
