import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'prepare.dart';
import 'receive.dart';
import 'sender.dart';

/// Same id on every phone running this app, so they find each other.
const _serviceId = 'com.photoorganizer.photo_organizer.share';

/// Point-to-point is the fastest Nearby mode (it upgrades to Wi-Fi Direct).
const _strategy = Strategy.P2P_POINT_TO_POINT;

/// Phone-to-phone sending between copies of this app with no Wi-Fi network
/// or hotspot (Google's Nearby Connections: Bluetooth to find each other,
/// Wi-Fi Direct to transfer). Messages: `offer` → `accept`/`decline` →
/// a `file` note per file payload → `done`.
class NearbyLink extends ChangeNotifier {
  NearbyLink(this.receiver, this.alias);

  final Receiver receiver;
  String alias;

  /// Nearby phones found while discovering: endpoint id → name.
  final Map<String, String> endpoints = {};
  bool discovering = false;
  bool advertising = false;

  // Receiving side, per sending phone.
  final Map<String, _Incoming> _incoming = {};
  // Sending side.
  _Outgoing? _out;

  /// Asks for Bluetooth / nearby-devices (and location on older Android).
  Future<bool> ensurePermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    bool ok(Permission p) => results[p]?.isGranted ?? false;
    final bluetooth = ok(Permission.bluetoothScan) && ok(Permission.bluetoothConnect);
    // Android 13+ uses "nearby devices"; older versions need location.
    return bluetooth && (ok(Permission.nearbyWifiDevices) || ok(Permission.locationWhenInUse));
  }

  Future<void> startDiscovery() async {
    if (discovering) return;
    if (!await ensurePermissions()) return;
    try {
      discovering = await Nearby().startDiscovery(
        alias,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (id, name, serviceId) {
          endpoints[id] = name;
          notifyListeners();
        },
        onEndpointLost: (id) {
          endpoints.remove(id);
          notifyListeners();
        },
      );
    } catch (e) {
      debugPrint('Nearby discovery failed: $e');
    }
    notifyListeners();
  }

  Future<void> stopDiscovery() async {
    if (!discovering) return;
    discovering = false;
    endpoints.clear();
    await Nearby().stopDiscovery();
    notifyListeners();
  }

  /// Lets other phones with this app send to us (while receiving is on).
  Future<void> startAdvertising() async {
    if (advertising) return;
    if (!await ensurePermissions()) return;
    try {
      advertising = await Nearby().startAdvertising(
        alias,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: (id, info) {
          _incoming[id] = _Incoming(info.endpointName);
          Nearby().acceptConnection(id, onPayLoadRecieved: _onPayload, onPayloadTransferUpdate: _onUpdate);
        },
        onConnectionResult: (id, status) {
          if (status != Status.CONNECTED) _incoming.remove(id);
        },
        onDisconnected: (id) {
          final s = _incoming.remove(id)?.session;
          if (s != null && !s.finished) receiver.finish(s, cancelled: true);
        },
      );
    } catch (e) {
      debugPrint('Nearby advertising failed: $e');
    }
    notifyListeners();
  }

  Future<void> stopAdvertising() async {
    if (!advertising) return;
    advertising = false;
    await Nearby().stopAdvertising();
    notifyListeners();
  }

  // ---- Payload handling (both roles share the plugin's one handler) ----

  void _onPayload(String endpoint, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final msg = jsonDecode(utf8.decode(payload.bytes!)) as Map<String, dynamic>;
      final out = _out;
      if (out != null && out.endpoint == endpoint) {
        out.onMessage(msg);
      } else {
        _incoming[endpoint]?.onMessage(this, endpoint, msg);
      }
    } else if (payload.type == PayloadType.FILE) {
      _incoming[endpoint]?.uris[payload.id] = payload.uri ?? '';
    }
  }

  void _onUpdate(String endpoint, PayloadTransferUpdate u) {
    final out = _out;
    if (out != null && out.endpoint == endpoint) {
      out.onUpdate(u);
    } else {
      _incoming[endpoint]?.onUpdate(this, u);
    }
  }

  Future<void> _sendJson(String endpoint, Map<String, Object?> msg) =>
      Nearby().sendBytesPayload(endpoint, Uint8List.fromList(utf8.encode(jsonEncode(msg))));

  // ---- Sending ----

  /// Sends [files] to the phone named [name] (found by discovery).
  Future<SendResult> send({
    required String name,
    required List<PreparedFile> files,
    CancelToken? cancel,
    void Function(int sentBytes, int totalBytes, int filesDone)? onProgress,
    void Function()? onAccepted,
  }) async {
    final endpoint = endpoints.entries.where((e) => e.value == name).firstOrNull?.key;
    if (endpoint == null) return SendResult(SendOutcome.failed, message: '$name isn\'t nearby');
    final out = _Outgoing(endpoint, files, onProgress);
    _out = out;
    try {
      final connected = Completer<bool>();
      await Nearby().requestConnection(
        alias,
        endpoint,
        onConnectionInitiated: (id, info) =>
            Nearby().acceptConnection(id, onPayLoadRecieved: _onPayload, onPayloadTransferUpdate: _onUpdate),
        onConnectionResult: (id, status) {
          if (!connected.isCompleted) connected.complete(status == Status.CONNECTED);
        },
        onDisconnected: (id) => out.disconnected(),
      );
      if (!await connected.future.timeout(const Duration(seconds: 40), onTimeout: () => false)) {
        return SendResult(SendOutcome.failed, message: 'Couldn\'t connect to $name');
      }
      await _sendJson(endpoint, {
        't': 'offer',
        'from': alias,
        'files': [
          for (var i = 0; i < files.length; i++)
            {'id': 'p$i', 'name': files[i].fileName, 'size': files[i].size, 'mime': files[i].mime, 'text': files[i].preview},
        ],
      });
      final yes = await out.answer.future.timeout(const Duration(minutes: 2), onTimeout: () => false);
      if (out.gotIt) {
        return SendResult(SendOutcome.nothingNeeded, sent: [for (final f in files) f.assetId]);
      }
      if (!yes) return SendResult(SendOutcome.declined, message: '$name declined');
      onAccepted?.call();
      final sent = <String>[], failed = <String>[];
      for (var i = 0; i < files.length; i++) {
        if (cancel?.cancelled ?? false) break;
        final payloadId = await Nearby().sendFilePayload(endpoint, files[i].file.path);
        final done = out.expect(payloadId);
        await _sendJson(endpoint, {'t': 'file', 'payload': payloadId, 'id': 'p$i'});
        final ok = await done.timeout(const Duration(minutes: 10), onTimeout: () => false);
        (ok ? sent : failed).add(files[i].assetId);
        out.filesDone++;
        out.report();
      }
      await _sendJson(endpoint, {'t': 'done'});
      if (cancel?.cancelled ?? false) {
        return SendResult(SendOutcome.cancelled, sent: sent, failed: failed);
      }
      return SendResult(failed.isEmpty ? SendOutcome.done : SendOutcome.failed,
          sent: sent, failed: failed, message: failed.isEmpty ? null : '${failed.length} files didn\'t arrive');
    } catch (e) {
      return SendResult(SendOutcome.failed, message: '$e');
    } finally {
      _out = null;
      // Give the last messages a moment, then hang up.
      Future<void>.delayed(const Duration(seconds: 2), () => Nearby().disconnectFromEndpoint(endpoint));
    }
  }
}

class _Outgoing {
  _Outgoing(this.endpoint, this.files, this.onProgress)
      : total = files.fold(0, (n, f) => n + f.size);

  final String endpoint;
  final List<PreparedFile> files;
  final void Function(int, int, int)? onProgress;
  final int total;
  final answer = Completer<bool>();

  /// The receiver already has everything it needs (a message).
  bool gotIt = false;
  final Map<int, Completer<bool>> _waiting = {};
  final Map<int, int> _bytes = {};
  int filesDone = 0;

  Future<bool> expect(int payloadId) => (_waiting[payloadId] ??= Completer<bool>()).future;

  void onMessage(Map<String, dynamic> msg) {
    if (msg['t'] == 'accept' && !answer.isCompleted) answer.complete(true);
    if (msg['t'] == 'decline' && !answer.isCompleted) answer.complete(false);
    if (msg['t'] == 'gotit' && !answer.isCompleted) {
      gotIt = true;
      answer.complete(true);
    }
  }

  void onUpdate(PayloadTransferUpdate u) {
    _bytes[u.id] = u.bytesTransferred;
    report();
    final c = _waiting[u.id] ??= Completer<bool>();
    if (c.isCompleted) return;
    if (u.status == PayloadStatus.SUCCESS) c.complete(true);
    if (u.status == PayloadStatus.FAILURE || u.status == PayloadStatus.CANCELED) c.complete(false);
  }

  void report() => onProgress?.call(_bytes.values.fold(0, (a, b) => a + b), total, filesDone);

  void disconnected() {
    if (!answer.isCompleted) answer.complete(false);
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.complete(false);
    }
  }
}

class _Incoming {
  _Incoming(this.from);

  final String from;
  ReceiveSession? session;
  final Map<int, String> uris = {};
  final Map<int, String> fileIds = {};
  final Set<int> complete = {};

  Future<void> onMessage(NearbyLink link, String endpoint, Map<String, dynamic> msg) async {
    switch (msg['t']) {
      case 'offer':
        final files = {
          for (final f in (msg['files'] as List).cast<Map>())
            f['id'] as String: IncomingFile(
                f['id'] as String, f['name'] as String, (f['size'] as num).toInt(), f['mime'] as String,
                preview: f['text'] as String?),
        };
        final accepted = await link.receiver.ask(IncomingRequest(from, files.values.toList(), 'Nearby'));
        if (accepted == null) {
          await link._sendJson(endpoint, {'t': 'decline'});
          return;
        }
        if (accepted.isEmpty) {
          await link._sendJson(endpoint, {'t': 'gotit'});
          return;
        }
        session = link.receiver.start(from, files, accepted, null);
        await link._sendJson(endpoint, {'t': 'accept'});
      case 'file':
        final payload = (msg['payload'] as num).toInt();
        fileIds[payload] = msg['id'] as String;
        if (complete.contains(payload)) await _save(link, payload);
      case 'done':
        final s = session;
        if (s != null) link.receiver.finish(s);
    }
  }

  Future<void> onUpdate(NearbyLink link, PayloadTransferUpdate u) async {
    final s = session;
    if (s == null) return;
    if (u.status == PayloadStatus.IN_PROGRESS) {
      link.receiver.ping();
    } else if (u.status == PayloadStatus.SUCCESS && uris.containsKey(u.id)) {
      complete.add(u.id);
      if (fileIds.containsKey(u.id)) await _save(link, u.id);
    }
  }

  /// Moves the finished payload out of Nearby's folder and into the gallery.
  Future<void> _save(NearbyLink link, int payload) async {
    final s = session;
    final id = fileIds.remove(payload);
    final uri = uris.remove(payload);
    if (s == null || id == null || uri == null) return;
    final tmp = p.join((await getTemporaryDirectory()).path, 'nearby_$payload');
    final moved = await Nearby().copyFileAndDeleteOriginal(uri, tmp);
    if (!moved) return;
    final file = File(tmp);
    await link.receiver.receive(s, id, file.openRead());
    if (await file.exists()) await file.delete();
  }
}
