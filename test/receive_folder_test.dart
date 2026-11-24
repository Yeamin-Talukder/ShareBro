import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/share/receive.dart';

/// Folders from the phone's folder picker, turned into places Android lets
/// the app save received files.
void main() {
  test('photos and videos: inside DCIM or Pictures', () {
    expect(phoneFolder('/storage/emulated/0/Pictures/Trips', mediaRoots).folder, 'Pictures/Trips');
    expect(phoneFolder('/storage/emulated/0/DCIM/Camera', mediaRoots).folder, 'DCIM/Camera');
    expect(phoneFolder('/storage/emulated/0/pictures', mediaRoots).folder, 'Pictures');
    expect(phoneFolder('/sdcard/DCIM/Friends/2026', mediaRoots).folder, 'DCIM/Friends/2026');
  });

  test('other files: inside Download or Documents', () {
    expect(phoneFolder('/storage/emulated/0/Download/From friends', filesRoots).folder, 'Download/From friends');
    expect(phoneFolder('/storage/emulated/0/Documents', filesRoots).folder, 'Documents');
  });

  test('places Android refuses are explained', () {
    final elsewhere = phoneFolder('/storage/emulated/0/Music/x', mediaRoots);
    expect(elsewhere.folder, isNull);
    expect(elsewhere.problem, contains('DCIM or Pictures'));
    expect(phoneFolder('/storage/emulated/0', filesRoots).folder, isNull);
    expect(phoneFolder('/storage/emulated/0/Pictures/x', filesRoots).folder, isNull);
    final card = phoneFolder('/storage/1A2B-3C4D/DCIM', mediaRoots);
    expect(card.folder, isNull);
    expect(card.problem, contains('memory card'));
  });
}
