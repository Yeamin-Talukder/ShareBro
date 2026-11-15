import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_organizer/share/nearby.dart';

void main() {
  // What permission_handler answers on Android 9–11: the Bluetooth and
  // nearby-devices permissions don't exist there, so they come back denied.
  final old = {
    Permission.bluetoothScan: PermissionStatus.denied,
    Permission.bluetoothAdvertise: PermissionStatus.denied,
    Permission.bluetoothConnect: PermissionStatus.denied,
    Permission.nearbyWifiDevices: PermissionStatus.denied,
    Permission.locationWhenInUse: PermissionStatus.granted,
  };

  test('Nearby works on Android 9–11 with location only', () {
    expect(nearbyAllowed(old, 28), isTrue);
    expect(nearbyAllowed(old, 30), isTrue);
    expect(nearbyAllowed({...old, Permission.locationWhenInUse: PermissionStatus.denied}, 30), isFalse);
  });

  test('Nearby on Android 12 needs Bluetooth and location', () {
    expect(nearbyAllowed(old, 31), isFalse);
    final bt = {...old, Permission.bluetoothScan: PermissionStatus.granted, Permission.bluetoothConnect: PermissionStatus.granted};
    expect(nearbyAllowed(bt, 31), isTrue);
    expect(nearbyAllowed({...bt, Permission.locationWhenInUse: PermissionStatus.denied}, 32), isFalse);
  });

  test('Nearby on Android 13+ takes nearby devices instead of location', () {
    final all = {
      Permission.bluetoothScan: PermissionStatus.granted,
      Permission.bluetoothConnect: PermissionStatus.granted,
      Permission.nearbyWifiDevices: PermissionStatus.granted,
      Permission.locationWhenInUse: PermissionStatus.denied,
    };
    expect(nearbyAllowed(all, 33), isTrue);
    expect(nearbyAllowed({...all, Permission.nearbyWifiDevices: PermissionStatus.denied}, 34), isFalse);
  });

  // The app asks for photos and videos together (RequestType.common). On
  // Android 13 that only counts as granted when both are declared, otherwise
  // phones like the Redmi Note show "needs photo access" after you allow it.
  test('the manifest declares photo and video access', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final permission in [
      'android.permission.READ_MEDIA_IMAGES',
      'android.permission.READ_MEDIA_VIDEO',
      'android.permission.READ_MEDIA_VISUAL_USER_SELECTED',
      'android.permission.ACCESS_MEDIA_LOCATION',
    ]) {
      expect(manifest, contains('android:name="$permission"'), reason: permission);
    }
  });
}
