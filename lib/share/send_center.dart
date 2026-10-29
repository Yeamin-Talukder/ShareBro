import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/db.dart';
import 'discovery.dart';
import '../scan/background.dart';
import 'nearby.dart';
import 'net.dart';
import 'prepare.dart';
import 'protocol.dart';
import 'receive.dart';
import 'sender.dart';
import 'server.dart';

enum JobStatus { preparing, waiting, asking, sending, done, declined, needsPin, failed, cancelled }

/// One send to one device: gallery items, files and/or a message.
class SendJob {
  SendJob({
    required this.id,
    this.personId,
    required this.personName,
    required this.items,
    required this.fingerprint,
    required this.deviceAlias,
    required this.quality,
    this.nearby = false,
  });

  /// Sent over Nearby Connections (no Wi-Fi) to the phone named
  /// [deviceAlias], instead of LocalSend.
  final bool nearby;

  final int id;

  /// Who the photos are for, when sent from a person's page.
  final int? personId;

  /// What the job is called in lists ("Maya", "3 files").
  final String personName;
  final List<SendItem> items;
  List<String> get assetIds => [for (final i in items) if (i.assetId != null) i.assetId!];
  int get count => items.length;

  /// "photos" when it's all gallery items, else "files".
  String get noun => items.every((i) => i.isAsset) ? 'photos' : 'files';
  final String fingerprint;
  final String deviceAlias;
  final SendQuality quality;

  JobStatus status = JobStatus.waiting;
  int prepared = 0, sentBytes = 0, totalBytes = 0, filesDone = 0;
  String? message;
  String? pin;

  /// When the friend accepted and bytes started flowing.
  DateTime? startedAt;

  /// Bytes per second so far, once there's enough to tell.
  double? get speed {
    final t = startedAt;
    if (t == null || status != JobStatus.sending) return null;
    final secs = DateTime.now().difference(t).inMilliseconds / 1000;
    return secs < 1 || sentBytes == 0 ? null : sentBytes / secs;
  }

  /// Time left at the current speed.
  Duration? get remaining {
    final v = speed;
    if (v == null || v <= 0 || totalBytes <= sentBytes) return null;
    return Duration(seconds: ((totalBytes - sentBytes) / v).ceil());
  }
  final cancel = CancelToken();

  bool get active => status == JobStatus.preparing || status == JobStatus.asking || status == JobStatus.sending;
  bool get finished => const {JobStatus.done, JobStatus.cancelled}.contains(status);
  bool get canRetry => const {JobStatus.declined, JobStatus.failed, JobStatus.needsPin}.contains(status);
  double get progress => switch (status) {
        JobStatus.preparing => items.isEmpty ? 0 : prepared / items.length * 0.1,
        JobStatus.sending => totalBytes == 0 ? 0.1 : 0.1 + 0.9 * sentBytes / totalBytes,
        JobStatus.done => 1,
        _ => 0,
      };
}

const _qualityKey = 'share_quality';

/// Everything sharing: our identity, discovery, the server for web
/// galleries, and the queue of sends to friends' phones.
class SendCenter extends ChangeNotifier {
  SendCenter._(this.db, this.identity, this.discovery, this.receiver, this.server, this.nearby)
      : _sender = LsSender(identity) {
    discovery.addListener(_kick);
    nearby.addListener(_kick);
  }

  final AppDb db;
  final ShareIdentity identity;
  final Discovery discovery;
  final Receiver receiver;
  final ShareServer server;
  final NearbyLink nearby;
  final LsSender _sender;

  final List<SendJob> jobs = [];
  int _nextId = 1;
  bool _running = false;
  bool _holdingDiscovery = false;
  SendQuality defaultQuality = SendQuality.original;

  static Future<SendCenter> create(AppDb db) async {
    final identity = await ShareIdentity.load(db);
    final discovery = Discovery(identity);
    final receiver = Receiver(db);
    await receiver.load();
    final center = SendCenter._(db, identity, discovery, receiver,
        ShareServer(identity, discovery, receiver), NearbyLink(receiver, identity.alias));
    final q = await db.setting(_qualityKey);
    center.defaultQuality =
        SendQuality.values.firstWhere((v) => v.name == q, orElse: () => SendQuality.original);
    // Receiving was left on last time: be reachable again.
    if (receiver.enabled) unawaited(center.setReceiving(true));
    return center;
  }

  bool _receivingOpen = false;

  /// Receive mode: stay findable on Wi-Fi (LocalSend) and Nearby, and keep
  /// running in the background, until it's turned off.
  Future<void> setReceiving(bool on) async {
    await receiver.setEnabled(on);
    if (on && !_receivingOpen) {
      _receivingOpen = true;
      await open();
      await nearby.startAdvertising();
      await KeepAlive.hold('ready', 'Ready to receive photos', 'Friends can send to "${identity.alias}"');
    } else if (!on && _receivingOpen) {
      _receivingOpen = false;
      await nearby.stopAdvertising();
      await close();
      await KeepAlive.release('ready');
    }
    notifyListeners();
  }

  Future<void> setDefaultQuality(SendQuality q) async {
    defaultQuality = q;
    await db.setSetting(_qualityKey, q.name);
    notifyListeners();
  }

  /// Opens discovery and the server (for screens that show nearby devices).
  Future<void> open() async {
    await server.start();
    await discovery.start();
  }

  Future<void> close() => discovery.stop();

  int get activeCount => jobs.where((j) => !j.finished && j.status != JobStatus.declined).length;

  /// Remembers [device] as [personId]'s phone.
  Future<void> pair(LsDevice device, int personId) async {
    await _save(device);
    await db.pairDevice(device.fingerprint, personId);
    notifyListeners();
  }

  Future<void> _save(LsDevice d) => db.saveDevice(
        fingerprint: d.fingerprint,
        alias: d.alias,
        model: d.info.deviceModel,
        type: d.info.deviceType.name,
        ip: d.ip,
        port: d.info.port,
        protocol: d.info.protocol,
      );

  /// Queues [assetIds] and [items] for [device]; it starts as soon as the
  /// device is reachable. With [personId], the device becomes their phone.
  Future<SendJob> enqueue({
    int? personId,
    required String personName,
    List<String> assetIds = const [],
    List<SendItem> items = const [],
    required LsDevice device,
    SendQuality? quality,
  }) async {
    if (personId != null) {
      await pair(device, personId);
    } else {
      await _save(device);
    }
    final job = SendJob(
      id: _nextId++,
      personId: personId,
      personName: personName,
      items: [for (final id in assetIds) SendItem.asset(id), ...items],
      fingerprint: device.fingerprint,
      deviceAlias: device.alias,
      quality: quality ?? defaultQuality,
    );
    jobs.add(job);
    notifyListeners();
    _kick();
    return job;
  }

  /// Queues [assetIds] and [items] for the nearby phone [name] (Nearby
  /// Connections).
  Future<SendJob> enqueueNearby({
    int? personId,
    required String personName,
    List<String> assetIds = const [],
    List<SendItem> items = const [],
    required String name,
    SendQuality? quality,
  }) async {
    final job = SendJob(
      id: _nextId++,
      personId: personId,
      personName: personName,
      items: [for (final id in assetIds) SendItem.asset(id), ...items],
      fingerprint: 'nearby:$name',
      deviceAlias: name,
      quality: quality ?? defaultQuality,
      nearby: true,
    );
    jobs.add(job);
    notifyListeners();
    _kick();
    return job;
  }

  /// "Send to everyone": each named person with a paired phone gets their
  /// photos they haven't been sent yet. Returns how many sends were queued.
  Future<int> sendToEveryone({int? tripId}) async {
    var queued = 0;
    for (final person in await db.people(tripId: tripId)) {
      if (person.name == null) continue;
      if (jobs.any((j) => j.personId == person.id && !j.finished)) continue;
      final devices = await db.savedDevices(personId: person.id);
      if (devices.isEmpty) continue;
      final sent = await db.sentTo(person.id);
      final fresh = [
        for (final ph in await db.photosOf(person.id, tripId: tripId))
          if (!sent.contains(ph.assetId)) ph.assetId,
      ];
      if (fresh.isEmpty) continue;
      final d = devices.first;
      final device = discovery.byFingerprint(d.fingerprint) ??
          LsDevice(
            info: LsInfo(
              alias: d.alias,
              fingerprint: d.fingerprint,
              port: d.port ?? lsPort,
              protocol: d.protocol ?? 'https',
            ),
            ip: d.ip ?? '',
            lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
          );
      await enqueue(personId: person.id, personName: person.name!, assetIds: fresh, device: device);
      queued++;
    }
    return queued;
  }

  void cancelJob(SendJob job) {
    job.cancel.cancel();
    if (!job.active) job.status = JobStatus.cancelled;
    notifyListeners();
  }

  void retry(SendJob job, {String? pin}) {
    job
      ..status = JobStatus.waiting
      ..message = null
      ..pin = pin ?? job.pin;
    notifyListeners();
    _kick();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }

  /// Looks for work whenever something changes (new job, device appeared).
  void _kick() {
    _syncKeepAlive();
    if (!_running) unawaited(_run());
  }

  void _syncKeepAlive() {
    final live = jobs.where((j) => j.active || j.status == JobStatus.waiting).toList();
    if (live.isEmpty) {
      KeepAlive.release('send');
      return;
    }
    final j = live.firstWhere((j) => j.active, orElse: () => live.first);
    final text = switch (j.status) {
      JobStatus.sending => '${j.personName}: ${j.filesDone} of ${j.count} ${j.noun}',
      JobStatus.asking => 'Waiting for ${j.deviceAlias} to accept',
      JobStatus.preparing => 'Getting ${j.count} ${j.noun} ready',
      _ => 'Waiting for ${j.deviceAlias} to be nearby',
    };
    KeepAlive.hold('send', live.length > 1 ? 'Sending to ${live.length} devices' : 'Sending ${j.noun}', text);
  }

  @override
  void notifyListeners() {
    _syncKeepAlive();
    super.notifyListeners();
  }

  Future<void> _run() async {
    _running = true;
    final pending = jobs.where((j) => j.status == JobStatus.waiting).isNotEmpty;
    if (pending && !_holdingDiscovery) {
      _holdingDiscovery = true;
      await open();
    }
    try {
      // One send at a time: receivers handle a single session at once.
      while (true) {
        final job = await _nextReady();
        if (job == null) break;
        await _runJob(job);
      }
    } finally {
      _running = false;
      final waiting = jobs.any((j) => j.status == JobStatus.waiting);
      if (_holdingDiscovery && !waiting) {
        _holdingDiscovery = false;
        await close();
      }
      // Phones that don't announce themselves get knocked on now and then.
      _retry?.cancel();
      if (waiting) _retry = Timer(const Duration(seconds: 20), _kick);
    }
  }

  Timer? _retry;

  /// The next waiting job whose phone we can reach right now.
  Future<SendJob?> _nextReady() async {
    for (final job in jobs.where((j) => j.status == JobStatus.waiting)) {
      if (job.cancel.cancelled) {
        job.status = JobStatus.cancelled;
        continue;
      }
      if (await _reach(job) != null) return job;
    }
    notifyListeners();
    return null;
  }

  /// The LocalSend device for [job], or (for Nearby jobs) a stand-in once
  /// the phone shows up in Nearby discovery.
  Future<LsDevice?> _reach(SendJob job) async {
    if (job.nearby) {
      if (!nearby.discovering) unawaited(nearby.startDiscovery());
      return nearby.endpoints.containsValue(job.deviceAlias)
          ? LsDevice(
              info: LsInfo(alias: job.deviceAlias, fingerprint: job.fingerprint),
              ip: '',
              lastSeen: DateTime.now(),
            )
          : null;
    }
    final seen = discovery.byFingerprint(job.fingerprint);
    if (seen != null) return seen;
    // Not announcing (multicast blocked?) — try where it was last time.
    final saved = (await db.savedDevices()).where((d) => d.fingerprint == job.fingerprint).firstOrNull;
    if (saved?.ip == null || saved!.ip!.isEmpty) return null;
    final probed = await discovery.probe(saved.ip!, port: saved.port ?? lsPort);
    return probed?.fingerprint == job.fingerprint ? probed : null;
  }

  Future<void> _runJob(SendJob job) async {
    final device = await _reach(job);
    if (device == null) return;
    final tmp = Directory(p.join((await getTemporaryDirectory()).path, 'send_${job.id}'));
    await tmp.create(recursive: true);
    try {
      job.status = JobStatus.preparing;
      notifyListeners();
      final files = await prepareItems(job.items, job.quality, tmp, onProgress: (done, _) {
        job.prepared = done;
        if (done % 10 == 0) notifyListeners();
      });
      if (job.cancel.cancelled) {
        job.status = JobStatus.cancelled;
        return;
      }
      job
        ..status = JobStatus.asking
        ..message = 'Waiting for ${device.alias} to accept…';
      notifyListeners();
      var lastPing = DateTime.now();
      final result = await (job.nearby
          ? nearby.send(
              name: job.deviceAlias,
              files: files,
              cancel: job.cancel,
              onAccepted: () {
                job
                  ..status = JobStatus.sending
                  ..message = null
                  ..startedAt = DateTime.now();
                notifyListeners();
              },
              onProgress: (sent, total, done) {
                job
                  ..sentBytes = sent
                  ..totalBytes = total
                  ..filesDone = done;
                final now = DateTime.now();
                if (now.difference(lastPing) > const Duration(milliseconds: 150)) {
                  lastPing = now;
                  notifyListeners();
                }
              },
            )
          : _sender.send(
        device: device,
        files: files,
        pin: job.pin,
        cancel: job.cancel,
        onAccepted: () {
          job
            ..status = JobStatus.sending
            ..message = null
            ..startedAt = DateTime.now();
          notifyListeners();
        },
        onProgress: (sent, total, done) {
          job
            ..sentBytes = sent
            ..totalBytes = total
            ..filesDone = done;
          // Progress arrives per chunk; repaint a few times a second.
          final now = DateTime.now();
          if (now.difference(lastPing) > const Duration(milliseconds: 150)) {
            lastPing = now;
            notifyListeners();
          }
        },
      ));
      final sentIds = result.sent.toSet();
      final photos = [for (final id in sentIds) if (!id.contains(':')) id];
      if (job.personId != null && photos.isNotEmpty) await db.markSent(job.personId!, photos, job.fingerprint);
      for (final f in files) {
        if (!sentIds.contains(f.assetId)) continue;
        await db.addTransfer(Transfer(
          incoming: false,
          peer: device.alias,
          fileName: f.fileName,
          size: f.size,
          mime: f.mime,
          location: f.isAsset ? f.assetId : f.file.path,
          text: f.preview,
        ));
      }
      if (!job.nearby) await _save(device);
      job
        ..message = result.message
        ..status = switch (result.outcome) {
          SendOutcome.done || SendOutcome.nothingNeeded => JobStatus.done,
          SendOutcome.declined => JobStatus.declined,
          SendOutcome.needsPin => JobStatus.needsPin,
          SendOutcome.cancelled => JobStatus.cancelled,
          SendOutcome.busy || SendOutcome.failed => JobStatus.failed,
        };
    } catch (e) {
      job
        ..status = JobStatus.failed
        ..message = '$e';
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
      notifyListeners();
    }
  }

  /// Prepares [assetIds] and [items] and opens a web page for them.
  Future<WebShare> openWebShare(String title, List<String> assetIds,
      {List<SendItem> items = const [],
      SendQuality? quality,
      String? pin,
      void Function(int, int)? onProgress}) async {
    await server.start();
    final tmp = Directory(p.join((await getTemporaryDirectory()).path,
        'web_${DateTime.now().millisecondsSinceEpoch}'));
    await tmp.create(recursive: true);
    final files = await prepareItems([for (final id in assetIds) SendItem.asset(id), ...items],
        quality ?? defaultQuality, tmp,
        onProgress: onProgress);
    return server.openShare(title, files, tmp, pin: pin);
  }
}
