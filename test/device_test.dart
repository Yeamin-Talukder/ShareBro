import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/platform/device.dart';
import 'package:photo_organizer/ui/desktop_soon.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android keeps every phone feature', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(Device.desktop, isFalse);
    expect(Device.photoLibrary, isTrue);
    expect(Device.nearbyNoNetwork, isTrue);
    expect(Device.installedApps, isTrue);
    expect(Device.selfUpdate, isTrue);
  });

  test('Windows switches the phone-only parts off', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(Device.desktop, isTrue);
    expect(Device.photoLibrary, isFalse);
    expect(Device.backgroundService, isFalse);
    expect(Device.systemNotifications, isFalse);
    expect(Device.nearbyNoNetwork, isFalse);
    expect(Device.installedApps, isFalse);
    // Windows updates itself from GitHub (its own installer).
    expect(Device.selfUpdate, isTrue);
  });

  testWidgets('desktop placeholder points to the Share tab', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DesktopSoon(title: 'Photos')),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Photos'), findsWidgets);
    expect(find.textContaining('use the Share tab'), findsOneWidget);
  });
}
