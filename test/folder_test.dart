import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/scan/scan_controller.dart';

void main() {
  test('picked folders become gallery-style relative paths', () {
    expect(folderToRelative('/storage/emulated/0/DCIM/Trip'), 'DCIM/Trip/');
    expect(folderToRelative('/storage/emulated/0/DCIM/Trip/'), 'DCIM/Trip/');
    expect(folderToRelative('/storage/1A2B-3C4D/Pictures/Cox'), 'Pictures/Cox/');
    expect(folderToRelative('primary:DCIM/Camera'), 'DCIM/Camera/');
    expect(folderToRelative('Download/Telegram'), 'Download/Telegram/');
  });
}
