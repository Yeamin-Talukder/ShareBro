import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

/// The first bytes of every SQLite file.
const _sqliteHeader = 'SQLite format 3';

/// Copies the app's database (names, faces, trips, groups, settings — but
/// not the photos themselves) to a dated file ready to save somewhere safe.
Future<File> makeBackup() async {
  final now = DateTime.now();
  final stamp = '${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final out = File(p.join(
      (await getTemporaryDirectory()).path, 'sharebro-backup-$stamp.db'));
  return File(await AppDb.filePath()).copy(out.path);
}

/// True if [file] looks like a backup made by [makeBackup].
Future<bool> isBackup(File file) async {
  try {
    final raf = await file.open();
    final head = await raf.read(_sqliteHeader.length);
    await raf.close();
    return String.fromCharCodes(head) == _sqliteHeader;
  } catch (_) {
    return false;
  }
}

/// Replaces the app's data with [file]. The caller must close the database
/// first and restart the app afterwards.
Future<void> restoreBackup(File file) async {
  final target = await AppDb.filePath();
  await file.copy(target);
  // Leftover journal files from the old database would corrupt the new one.
  for (final suffix in ['-journal', '-wal', '-shm']) {
    final f = File('$target$suffix');
    if (await f.exists()) await f.delete();
  }
}
