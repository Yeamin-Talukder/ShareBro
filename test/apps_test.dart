import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/apps.dart';

void main() {
  test('a normal app is sent as one named APK', () {
    final app = InstalledApp.fromMap({
      'package': 'com.example.chat',
      'name': 'Chat: Pro',
      'version': '2.4.1',
      'files': ['/data/app/x/base.apk'],
      'size': 1000,
    });
    final items = app.toSendItems();
    expect(items, hasLength(1));
    expect(items.single.name, 'Chat Pro 2.4.1.apk');
    expect(items.single.path, '/data/app/x/base.apk');
  });

  test('an app bundle is sent as a folder with every part', () {
    final app = InstalledApp.fromMap({
      'package': 'com.example.game',
      'name': 'Game',
      'version': '1.0',
      'files': ['/data/app/y/base.apk', '/data/app/y/split_config.arm64_v8a.apk'],
    });
    expect(app.isSplit, isTrue);
    expect([for (final i in app.toSendItems()) i.name],
        ['Game 1.0/base.apk', 'Game 1.0/split_config.arm64_v8a.apk']);
  });
}
