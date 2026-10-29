import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../ui/widgets.dart' show AssetThumb;
import 'receive.dart';
import 'send_center.dart';

/// Android's notification shade (see NotifyChannel.kt): progress with a
/// thumbnail, buttons, a photo preview when done, and the Android 16 status
/// bar chip.
class Notify {
  static const _channel = MethodChannel('photo_organizer/notify');
  static void Function(int id, String action)? onAction;
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action') {
        final args = (call.arguments as Map).cast<String, Object?>();
        onAction?.call(args['id']! as int, args['action']! as String);
      }
    });
  }

  /// [kind]: 'request', 'progress', 'scan' or 'done'. [progress] 0..1, or
  /// null for "working on it". [chip] is the short status-bar text.
  static Future<void> show({
    required int id,
    required String kind,
    required String title,
    String text = '',
    String? sub,
    double? progress,
    String? chip,
    Uint8List? thumb,
    Uint8List? picture,
    List<(String id, String label)> actions = const [],
  }) async {
    _listen();
    try {
      await _channel.invokeMethod('show', {
        'id': id,
        'kind': kind,
        'title': title,
        'text': text,
        'sub': sub,
        'progress': progress,
        'chip': chip,
        'thumb': thumb,
        'picture': picture,
        'actions': [
          for (final (a, l) in actions) {'id': a, 'label': l},
        ],
      });
    } on MissingPluginException {
      // Not on Android (tests, desktop).
    } on PlatformException catch (e) {
      debugPrint('Notification failed: ${e.message}');
    }
  }

  static Future<void> cancel(int id) async {
    try {
      await _channel.invokeMethod('cancel', {'id': id});
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // Already gone.
    }
  }
}

/// Keeps the notification shade in step with what's happening: live
/// progress for every send, receive and scan; incoming requests and
/// "done" notices while the app is in the background (the island shows
/// them in the app).
class NotifyBridge with WidgetsBindingObserver {
  NotifyBridge(this.c) {
    WidgetsBinding.instance.addObserver(this);
    c.sharing.addListener(_onSharing);
    c.sharing.receiver.addListener(_onReceiver);
    c.sharing.receiver.missed.addListener(_onMissed);
    c.addListener(_onScan);
    Notify.onAction = _onAction;
    _settled.addAll([
      for (final j in c.sharing.jobs)
        if (j.finished || j.canRetry) j.id,
    ]);
  }

  final ScanController c;

  static const _request = 2000, _missed = 2001, _receive = 3000, _received = 3001, _scan = 4000;
  static int _progressId(SendJob j) => 10000 + j.id;
  static int _doneId(SendJob j) => 20000 + j.id;

  bool _foreground = true;
  final Map<int, DateTime> _last = {};
  final Set<int> _settled = {};
  final Map<int, Uint8List?> _thumbs = {};
  IncomingRequest? _askShown;
  ReceiveSession? _sessionShown, _sessionDone;
  bool _scanShown = false;

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.sharing.removeListener(_onSharing);
    c.sharing.receiver.removeListener(_onReceiver);
    c.sharing.receiver.missed.removeListener(_onMissed);
    c.removeListener(_onScan);
  }

  /// A send we turned away because Receive was off: say so on this phone.
  Future<void> _onMissed() async {
    final req = c.sharing.receiver.missed.value;
    if (req == null) return;
    await Notify.show(
      id: _missed,
      kind: 'request',
      title: '${req.from} tried to send you ${req.summary}',
      text: 'Receive is off. Open ShareBro (or turn on Receive) and ask them to send again.',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Leaving the app with a question open: ask in the shade instead.
    if (!_foreground) _onReceiver();
  }

  /// Progress updates are throttled; Android drops rapid-fire ones anyway.
  bool _due(int id, {int ms = 800}) {
    final now = DateTime.now();
    final last = _last[id];
    if (last != null && now.difference(last).inMilliseconds < ms) return false;
    _last[id] = now;
    return true;
  }

  Future<Uint8List?> _thumbFor(String? assetId, {int size = 160}) async {
    if (assetId == null) return null;
    final key = Object.hash(assetId, size);
    if (_thumbs.containsKey(key)) return _thumbs[key];
    final a = await AssetThumb.entity(assetId);
    return _thumbs[key] = await a?.thumbnailDataWithSize(ThumbnailSize.square(size), quality: 80);
  }

  // ---- Sending ----

  Future<void> _onSharing() async {
    for (final j in c.sharing.jobs) {
      if (_settled.contains(j.id)) continue;
      final firstPhoto = j.assetIds.isEmpty ? null : j.assetIds.first;
      if (j.active || j.status == JobStatus.waiting) {
        if (!_due(_progressId(j))) continue;
        final (text, progress) = switch (j.status) {
          JobStatus.waiting => ('Waiting for ${j.deviceAlias} to be nearby', null),
          JobStatus.preparing => ('Getting ${j.count} ${j.noun} ready', null),
          JobStatus.asking => ('Waiting for ${j.deviceAlias} to accept', null),
          _ => (
            '${j.filesDone} of ${j.count} ${j.noun}'
                '${j.remaining == null ? '' : ' · ${_short(j.remaining!)} left'}',
            j.progress,
          ),
        };
        await Notify.show(
          id: _progressId(j),
          kind: 'progress',
          title: 'Sending to ${j.deviceAlias}',
          text: text,
          sub: j.speed == null ? null : '${formatBytes(j.speed!.round())}/s',
          progress: progress,
          chip: progress == null ? j.deviceAlias : '${(progress * 100).round()}%',
          thumb: await _thumbFor(firstPhoto),
          actions: const [('cancel', 'Cancel')],
        );
        continue;
      }
      // Finished one way or another.
      _settled.add(j.id);
      await Notify.cancel(_progressId(j));
      if (_foreground) continue;
      if (j.status == JobStatus.done) {
        await Notify.show(
          id: _doneId(j),
          kind: 'done',
          title: 'Sent ${j.count} ${j.noun} to ${j.deviceAlias} ✓',
          text: '${j.personName} arrived on ${j.deviceAlias}',
          thumb: await _thumbFor(firstPhoto),
        );
      } else if (j.status != JobStatus.cancelled) {
        await Notify.show(
          id: _doneId(j),
          kind: 'done',
          title: 'Couldn\'t finish sending to ${j.deviceAlias}',
          text: j.message ?? 'Open ShareBro to try again',
        );
      }
    }
  }

  // ---- Receiving ----

  Future<void> _onReceiver() async {
    final r = c.sharing.receiver;
    final req = r.pending;
    if (req != null && !req.answered && !_foreground && _askShown != req) {
      _askShown = req;
      await Notify.show(
        id: _request,
        kind: 'request',
        title: '${req.from} wants to send you ${req.summary}',
        text: '${formatBytes(req.totalBytes)} over ${req.via}',
        actions: const [('decline', 'Decline'), ('accept', 'Accept')],
      );
    } else if ((req == null || req.answered) && _askShown != null) {
      _askShown = null;
      await Notify.cancel(_request);
    }

    final s = r.session;
    if (s == null) return;
    if (!s.finished) {
      _sessionShown = s;
      if (!_due(_receive)) return;
      final total = s.totalBytes;
      final p = total == 0 ? null : s.bytes / total;
      await Notify.show(
        id: _receive,
        kind: 'progress',
        title: 'Receiving from ${s.from}',
        text: '${s.done.length} of ${s.tokens.length} · ${formatBytes(s.bytes)} of ${formatBytes(total)}',
        progress: p,
        chip: p == null ? s.from : '${(p * 100).round()}%',
        thumb: await _thumbFor(s.savedIds.isEmpty ? null : s.savedIds.last),
      );
    } else if (_sessionDone != s) {
      _sessionDone = s;
      if (_sessionShown == s) await Notify.cancel(_receive);
      if (_foreground || s.cancelled || s.done.isEmpty) return;
      final photos = s.savedIds.length, files = s.savedFiles;
      await Notify.show(
        id: _received,
        kind: 'done',
        title: 'Got ${s.done.length} ${files == 0 ? (photos == 1 ? 'photo' : 'photos') : 'files'} from ${s.from} ✓',
        text: photos > 0
            ? 'Saved to the $receivedAlbum album · faces will be found'
            : 'Saved to Download/$receivedAlbum',
        picture: await _thumbFor(s.savedIds.isEmpty ? null : s.savedIds.first, size: 720),
      );
    }
  }

  // ---- Scanning ----

  Future<void> _onScan() async {
    if (c.running && c.total > 0) {
      if (!_due(_scan, ms: 1500)) return;
      _scanShown = true;
      await Notify.show(
        id: _scan,
        kind: 'scan',
        title: 'Finding faces · ${_n(c.done)} of ${_n(c.total)}',
        text: '${c.peopleSoFar} ${c.peopleSoFar == 1 ? 'person' : 'people'} so far',
        progress: c.done / c.total,
        chip: '${(c.done / c.total * 100).round()}%',
        actions: const [('stop', 'Stop')],
      );
    } else if (!c.running && _scanShown) {
      _scanShown = false;
      await Notify.cancel(_scan);
    }
  }

  // ---- Buttons ----

  void _onAction(int id, String action) {
    switch (action) {
      case 'accept' || 'decline':
        c.sharing.receiver.pending?.answer(action == 'accept');
        unawaited(Notify.cancel(_request));
      case 'cancel':
        for (final j in c.sharing.jobs) {
          if (_progressId(j) == id) c.sharing.cancelJob(j);
        }
      case 'stop':
        c.cancel();
    }
  }

  static String _n(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  static String _short(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';
}
