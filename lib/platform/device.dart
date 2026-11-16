import 'package:flutter/foundation.dart';

/// What this device can do. ShareBro was built for Android; on desktop
/// (Windows first) the phone-only parts are switched off until they have
/// desktop versions. See design/windows-port-plan.md.
///
/// Uses [defaultTargetPlatform] rather than `dart:io`'s `Platform`, so widget
/// tests (which run on a desktop but report Android) keep the phone behaviour.
abstract final class Device {
  static bool get android => defaultTargetPlatform == TargetPlatform.android;

  static bool get phone =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static bool get desktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// The phone's photo library (photos, albums, favourites, trash) and
  /// scanning it for faces. Desktop gets a folder-based library later.
  static bool get photoLibrary => phone;

  /// A background service that keeps scans and transfers going with the
  /// screen off. Desktop apps keep running anyway.
  static bool get backgroundService => phone;

  /// Rich system notifications (progress, Accept / Decline, previews).
  /// Desktop uses the in-app island only for now.
  static bool get systemNotifications => android;

  /// Sending to ShareBro phones with no network (Bluetooth / Wi-Fi Direct).
  static bool get nearbyNoNetwork => android;

  /// Sending installed apps, and installing apps friends send.
  static bool get installedApps => android;

  /// The in-app updater, which downloads and installs a new APK.
  static bool get selfUpdate => android;
}
