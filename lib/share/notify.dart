import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../ui/widgets.dart' show AssetThumb;
import 'receive.dart';
import 'send_center.dart';

/// Android's notification shade (see NotifyChannel.kt): progress with a
/// thumbnail, buttons, a photo preview when done, grouped summaries, and
/// the Android 16 status bar chip. A tap opens the screen it's about.
class Notify {
  static const _channel = MethodChannel('photo_organizer/notify');
  static void Function(int id, String action)? onAction;

  /// A notification was tapped: open this screen ('scan', 'review',
  /// 'people', 'receive', 'transfers').
  static void Function(String target)? onOpen;
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'action':
          final args = (call.arguments as Map).cast<String, Object?>();
          onAction?.call(args['id']! as int, args['action']! as String);
        case 'open':
          onOpen?.call(call.arguments as String);
      }
    });
  }

  /// Picks up a tap that started the app before Dart was listening.
  static Future<void> takeOpen() async {
    _listen();
    try {
      final target = await _channel.invokeMethod<String>('takeOpen');
      if (target != null) onOpen?.call(target);
    } on MissingPluginException {
      // Not on Android.
    }
  }

  /// [kind]: 'request', 'progress', 'scan', 'done' or 'summary' (the head
  /// of a [group]). [progress] 0..1, or null for "working on it". [chip] is
  /// the short status-bar text, [segments] how many pieces the Android 16
  /// bar is split into, [open] the screen a tap opens, [lines] a summary's
  /// rows.
  static Future<void> show({
    required int id,
    required String kind,
    required String title,
    String text = '',
    String? sub,
    double? progress,
    String? chip,
    int? segments,
    Uint8List? thumb,
    Uint8List? picture,
    String? open,
    String? group,
    List<String>? lines,
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
        'segments': segments,
        'thumb': thumb,
        'picture': picture,
        'open': open,
        'group': group,
        'lines': lines,
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
/// progress for every send, receive and scan; incoming requests, "done"
/// and "didn't finish" notices while the app is in the background (the
/// island shows them in the app). Titles say what happened, the line under
/// says what's next.
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

  static const _request = 2000,
      _missed = 2001,
      _receive = 3000,
      _received = 3001,
      _scan = 4000,
      _scanDone = 4001,
      _summary = 1999;
  static int _progressId(SendJob j) => 10000 + j.id;
  static int _doneId(SendJob j) => 20000 + j.id;

  /// Finished transfers stack in this group under one summary.
  static const _doneGroup = 'transfers';

  bool _foreground = true;
  final Map<int, DateTime> _last = {};
  final Set<int> _settled = {};
  final Map<int, Uint8List?> _thumbs = {};
  IncomingRequest? _askShown;
  ReceiveSession? _sessionShown, _sessionDone;
  bool _scanShown = false;

  /// The running "scan" is really a face model upgrade.
  bool _upgradeShown = false;

  /// When this scan's progress was first seen, and how far it was then:
  /// for "about 4 min left".
  DateTime? _scanFrom;
  int _scanFromDone = 0;

  /// Rows of the "transfers done" summary, newest first, while the shade
  /// still has them.
  final List<String> _doneLines = [];

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
      text: 'Receive was off. Turn it on and ask them to send again.',
      open: 'receive',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // Back in the app: the island shows it all; clear the "done" pile.
      _doneLines.clear();
      unawaited(Notify.cancel(_summary));
    } else {
      // Leaving the app with a question open: ask in the shade instead.
      _onReceiver();
    }
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

  /// A finished transfer: posted into the group, with the summary on top
  /// once there's more than one.
  Future<void> _done(int id, String title, String text, {Uint8List? thumb, Uint8List? picture,
      String open = 'transfers', List<(String, String)> actions = const []}) async {
    await Notify.show(
      id: id,
      kind: 'done',
      title: title,
      text: text,
      thumb: thumb,
      picture: picture,
      open: open,
      group: _doneGroup,
      actions: actions,
    );
    _doneLines.insert(0, title);
    if (_doneLines.length < 2) return;
    await Notify.show(
      id: _summary,
      kind: 'summary',
      title: '${_doneLines.length} transfers done',
      text: 'ShareBro',
      lines: _doneLines.take(6).toList(),
      open: 'transfers',
      group: _doneGroup,
    );
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
          JobStatus.preparing => ('Getting them ready', null),
          JobStatus.asking => ('Waiting for ${j.deviceAlias} to accept', null),
          _ => (
              '${j.filesDone} of ${j.count}${j.remaining == null ? '' : ' · about ${_short(j.remaining!)} left'}',
              j.progress,
            ),
        };
        await Notify.show(
          id: _progressId(j),
          kind: 'progress',
          title: 'Sending ${j.count} ${j.noun} to ${j.deviceAlias}',
          text: text,
          sub: j.speed == null ? null : '${formatBytes(j.speed!.round())}/s',
          progress: progress,
          segments: j.count,
          chip: progress == null ? j.deviceAlias : '${(progress * 100).round()}% · ${j.deviceAlias}',
          thumb: await _thumbFor(firstPhoto),
          open: 'transfers',
          actions: const [('cancel', 'Cancel')],
        );
        continue;
      }
      // Finished one way or another.
      _settled.add(j.id);
      await Notify.cancel(_progressId(j));
      if (_foreground) continue;
      if (j.status == JobStatus.done) {
        await _done(
          _doneId(j),
          'Sent ${j.count} ${j.noun} to ${j.deviceAlias}',
          '${j.personName}\'s ${j.noun} are on ${j.deviceAlias}',
          thumb: await _thumbFor(firstPhoto),
        );
      } else if (j.status != JobStatus.cancelled) {
        await Notify.show(
          id: _doneId(j),
          kind: 'done',
          title: j.filesDone > 0
              ? 'Sending to ${j.deviceAlias} stopped at ${j.filesDone} of ${j.count}'
              : 'Couldn\'t send to ${j.deviceAlias}',
          text: '${j.message ?? 'Something went wrong on the way.'} '
              '${j.canRetry ? 'Retry picks up where it stopped.' : ''}'
              .trim(),
          thumb: await _thumbFor(firstPhoto),
          open: 'transfers',
          actions: [if (j.canRetry) ('retry', 'Retry'), ('dismiss', 'Dismiss')],
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
        text: '${formatBytes(req.totalBytes)} · ${req.via} · '
            '${req.allMedia ? 'saves to the $receivedAlbum album' : 'saves to Download/$receivedAlbum'}',
        open: 'receive',
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
        title: 'Getting ${s.tokens.length} from ${s.from}',
        text: '${s.done.length} of ${s.tokens.length} · ${formatBytes(s.bytes)} of ${formatBytes(total)}',
        progress: p,
        segments: s.tokens.length,
        chip: p == null ? s.from : '${(p * 100).round()}% · ${s.from}',
        thumb: await _thumbFor(s.savedIds.isEmpty ? null : s.savedIds.last),
        open: 'receive',
      );
    } else if (_sessionDone != s) {
      _sessionDone = s;
      if (_sessionShown == s) await Notify.cancel(_receive);
      if (_foreground || s.cancelled || s.done.isEmpty) return;
      final photos = s.savedIds.length, files = s.savedFiles;
      final what = files == 0 ? (photos == 1 ? 'photo' : 'photos') : 'files';
      await _done(
        _received,
        '${s.done.length} $what from ${s.from}',
        photos > 0 ? 'In the $receivedAlbum album · faces are being found' : 'In Download/$receivedAlbum',
        picture: await _sheet(s.savedIds),
        open: 'receive',
        actions: const [('open:receive', 'View photos')],
      );
    }
  }

  /// A contact sheet of what arrived: one big photo and two small ones
  /// beside it (Android shows one picture per notification).
  Future<Uint8List?> _sheet(List<String> ids) async {
    if (ids.isEmpty) return null;
    try {
      final shots = [
        for (final id in ids.take(3))
          ?await _thumbFor(id, size: 480),
      ];
      if (shots.isEmpty) return null;
      final images = [
        for (final b in shots) (await (await ui.instantiateImageCodec(b)).getNextFrame()).image,
      ];
      const w = 720.0, h = 360.0, gap = 6.0;
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      void cover(ui.Image img, ui.Rect to) {
        // Crop to fill, like a photo tile.
        final s = img.width / img.height, t = to.width / to.height;
        final src = s > t
            ? ui.Rect.fromCenter(
                center: ui.Offset(img.width / 2, img.height / 2), width: img.height * t, height: img.height.toDouble())
            : ui.Rect.fromCenter(
                center: ui.Offset(img.width / 2, img.height / 2), width: img.width.toDouble(), height: img.width / t);
        canvas.drawImageRect(img, src, to, ui.Paint()..filterQuality = ui.FilterQuality.medium);
      }

      if (images.length == 1) {
        cover(images[0], const ui.Rect.fromLTWH(0, 0, w, h));
      } else {
        const big = w * 2 / 3 - gap / 2;
        cover(images[0], const ui.Rect.fromLTWH(0, 0, big, h));
        final small = images.length == 2 ? h : (h - gap) / 2;
        cover(images[1], ui.Rect.fromLTWH(big + gap, 0, w - big - gap, small));
        if (images.length > 2) cover(images[2], ui.Rect.fromLTWH(big + gap, small + gap, w - big - gap, small));
      }
      final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      for (final i in images) {
        i.dispose();
      }
      out.dispose();
      return png?.buffer.asUint8List();
    } catch (e) {
      debugPrint('Contact sheet failed: $e');
      return null;
    }
  }

  // ---- Scanning ----

  Future<void> _onScan() async {
    if (c.running && c.total > 0) {
      if (!_scanShown) {
        _scanFrom = DateTime.now();
        _scanFromDone = c.done;
        await Notify.cancel(_scanDone);
      }
      if (!_due(_scan, ms: 1500)) return;
      _scanShown = true;
      _upgradeShown = c.upgrading;
      final left = _scanLeft();
      final p = c.done / c.total;
      await Notify.show(
        id: _scan,
        kind: 'scan',
        title: c.upgrading ? 'Updating face matching' : 'Finding faces',
        text: '${_n(c.done)} of ${_n(c.total)} ${c.upgrading ? 'faces' : 'photos'}'
            '${left == null ? '' : ' · about ${_short(left)} left'}',
        sub: c.albumName,
        progress: p,
        chip: left == null ? '${(p * 100).round()}%' : '${(p * 100).round()}% · ${_short(left)}',
        // The newest face it found, or the photo it's on.
        thumb: c.recentFaces.isNotEmpty ? c.recentFaces.first : c.preview,
        open: 'scan',
        actions: const [('stop', 'Stop')],
      );
    } else if (!c.running && _scanShown) {
      _scanShown = false;
      await Notify.cancel(_scan);
      // Finished while you were away: say what it found and what's next.
      final wasUpgrade = _upgradeShown;
      _upgradeShown = false;
      if (_foreground || c.error != null || c.stopped || wasUpgrade) return;
      final people = c.peopleFound ?? 0;
      await Notify.show(
        id: _scanDone,
        kind: 'done',
        title: c.facesFound == 0
            ? 'No faces in ${_n(c.done)} photos'
            : 'Found $people ${people == 1 ? 'person' : 'people'} in ${_n(c.done)} photos',
        text: c.facesFound == 0 ? 'Try another album or folder' : 'Name them, or check the faces it wasn\'t sure about',
        sub: c.albumName,
        thumb: c.recentFaces.isNotEmpty ? c.recentFaces.first : null,
        open: c.facesFound == 0 ? 'people' : 'review',
        actions: c.facesFound == 0 ? const [] : const [('open:review', 'Review faces'), ('open:people', 'Open People')],
      );
    }
  }

  /// Time left at the pace so far, once there's enough to go on.
  Duration? _scanLeft() {
    final from = _scanFrom;
    final done = c.done - _scanFromDone;
    if (from == null || done < 10) return null;
    final per = DateTime.now().difference(from).inMilliseconds / done;
    return Duration(milliseconds: (per * (c.total - c.done)).round());
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
      case 'retry':
        for (final j in c.sharing.jobs) {
          if (_doneId(j) == id && j.canRetry) {
            _settled.remove(j.id);
            c.sharing.retry(j);
          }
        }
        unawaited(Notify.cancel(id));
      case 'dismiss':
        unawaited(Notify.cancel(id));
      case 'stop':
        c.cancel();
    }
  }

  static String _n(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  static String _short(Duration d) => d.inHours >= 1
      ? '${d.inHours} h ${d.inMinutes % 60} min'
      : d.inMinutes >= 1
          ? '${d.inMinutes} min'
          : '${d.inSeconds} s';
}
