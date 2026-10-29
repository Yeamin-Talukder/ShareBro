import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app running (CPU and Wi-Fi awake) while anything needs it —
/// a scan, a send, receiving, or a shared link — and shows what it's doing
/// as one notification. Each user holds a named reason; the service stops
/// when the last one is released.
class KeepAlive {
  static final Map<String, (String title, String text)> _reasons = {};
  static bool _initialized = false;
  static Future<void> _queue = Future.value();

  static bool get _supported => Platform.isAndroid;

  static bool holding(String key) => _reasons.containsKey(key);

  static Future<void> hold(String key, String title, String text) {
    _reasons[key] = (title, text);
    return _sync();
  }

  static Future<void> release(String key) {
    if (_reasons.remove(key) == null) return Future.value();
    return _sync();
  }

  /// Service calls are serialised so quick hold/release pairs can't race.
  static Future<void> _sync() => _queue = _queue.then((_) => _apply()).catchError((Object e) {
        debugPrint('Keep-alive: $e');
      });

  static Future<void> _apply() async {
    if (!_supported) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (_reasons.isEmpty) {
      if (running) await FlutterForegroundTask.stopService();
      return;
    }
    // A scan is the most interesting thing to show; otherwise the newest.
    final (title, text) = _reasons['scan'] ?? _reasons.values.last;
    final extra = _reasons.length > 1 ? ' (+${_reasons.length - 1} more)' : '';
    if (running) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: '$text$extra');
      return;
    }
    if (!_initialized) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          // Kept quiet and folded away: the rich progress notifications
          // (see share/notify.dart) carry the details.
          channelId: 'background',
          channelName: 'Background work',
          channelDescription: 'Keeps ShareBro running while it scans, sends or receives',
          channelImportance: NotificationChannelImportance.MIN,
          priority: NotificationPriority.MIN,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          allowWakeLock: true,
          // Transfers need Wi-Fi to stay up with the screen off.
          allowWifiLock: true,
          allowAutoRestart: false,
        ),
      );
      _initialized = true;
    }
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: title,
      notificationText: '$text$extra',
    );
  }
}

/// Scan progress in the shared notification.
class ScanNotification {
  static Future<void> start(String text) => KeepAlive.hold('scan', 'Scanning photos for faces', text);
  static Future<void> update(String text) => KeepAlive.hold('scan', 'Scanning photos for faces', text);
  static Future<void> stop() => KeepAlive.release('scan');
}
