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

  /// What the background notice says right now (to skip repeat updates).
  static String? _shown;

  static String _activity(String key) => switch (key) {
        'scan' => 'scanning',
        'send' => 'sending',
        'receive' => 'receiving',
        'receive-ask' => 'waiting for your answer',
        'ready' => 'ready to receive',
        _ when key.startsWith('web-') => 'sharing a link',
        _ => 'working',
      };

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
    // Just a short summary: the rich notifications (share/notify.dart)
    // carry the live details, so this one doesn't repeat them.
    const title = 'ShareBro is working';
    final doing = <String>{for (final key in _reasons.keys) _activity(key)}.join(' · ');
    final text = doing[0].toUpperCase() + doing.substring(1);
    if (running) {
      if (text == _shown) return;
      _shown = text;
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      return;
    }
    _shown = text;
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
      notificationText: text,
    );
  }
}

/// Scan progress in the shared notification.
class ScanNotification {
  static Future<void> start(String text) => KeepAlive.hold('scan', 'Scanning photos for faces', text);
  static Future<void> update(String text) => KeepAlive.hold('scan', 'Scanning photos for faces', text);
  static Future<void> stop() => KeepAlive.release('scan');
}
