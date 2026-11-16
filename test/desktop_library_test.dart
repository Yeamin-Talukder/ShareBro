import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:photo_organizer/platform/desktop_library.dart';
import 'package:photo_organizer/scan/desktop_folders.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('sharebro_desktop_'));
  tearDown(() async => dir.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File(p.join(dir.path, name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    return f.path;
  }

  group('desktopEntity', () {
    test('reads the size, type and name from a JPEG', () async {
      final path = await write('beach.jpg', img.encodeJpg(img.Image(width: 40, height: 20)));
      final a = (await desktopEntity(path))!;
      expect(a.id, path);
      expect((a.width, a.height), (40, 20));
      expect(a.title, 'beach.jpg');
      expect(a.relativePath, dir.path);
      expect(a.mimeType, 'image/jpeg');
    });

    test('a photo turned by EXIF reports its upright size', () async {
      final im = img.Image(width: 40, height: 20);
      im.exif.imageIfd.orientation = 6; // shown turned 90°
      final path = await write('turned.jpg', img.encodeJpg(im));
      final a = (await desktopEntity(path))!;
      expect((a.orientatedWidth, a.orientatedHeight), (20, 40));
    });

    test('PNGs work too', () async {
      final path = await write('shot.png', img.encodePng(img.Image(width: 7, height: 9)));
      final a = (await desktopEntity(path))!;
      expect((a.width, a.height), (7, 9));
      expect(a.mimeType, 'image/png');
    });

    test('uses the scanned date when there is one', () async {
      final path = await write('dated.jpg', img.encodeJpg(img.Image(width: 4, height: 4)));
      final taken = DateTime(2026, 10, 17, 9, 52);
      desktopTakenAt = (_) async => taken;
      addTearDown(() => desktopTakenAt = null);
      expect((await desktopEntity(path))!.createDateTime, taken);
    });

    test('a missing file is null', () async {
      expect(await desktopEntity(p.join(dir.path, 'gone.jpg')), isNull);
    });
  });

  group('listPhotoFiles', () {
    test('finds photos in subfolders, skipping hidden folders and other files', () async {
      final jpg = img.encodeJpg(img.Image(width: 2, height: 2));
      final a = await write('a.jpg', jpg);
      final b = await write(p.join('day 2', 'B.JPEG'), jpg);
      await write(p.join('.thumbs', 'c.jpg'), jpg);
      await write('notes.txt', [1, 2, 3]);
      final found = await listPhotoFiles(dir.path);
      expect(found.toSet(), {a, b});
    });
  });

  test('folder keys round-trip', () {
    final key = desktopFolderKey(dir.path);
    expect(desktopFolderOf(key), p.normalize(dir.path));
    expect(desktopFolderOf('12345'), isNull);
  });
}
