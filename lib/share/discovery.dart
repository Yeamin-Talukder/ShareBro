import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'net.dart';
import 'protocol.dart';

/// Finds LocalSend devices on the local network, the way LocalSend does:
/// UDP multicast announcements answered with `POST /register` (or a UDP
/// reply), with a full-subnet scan and manual IP entry as fallbacks.
class Discovery extends ChangeNotifier {
  Discovery(this.identity);

  final ShareIdentity identity;
  final Map<String, LsDevice> _devices = {};
  RawDatagramSocket? _socket;
  Timer? _announcer;
  int _users = 0;
  bool scanning = false;

  /// Devices heard from recently, most recent first.
  List<LsDevice> get devices => _devices.values.where((d) => d.isFresh).toList()
    ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

  LsDevice? byFingerprint(String fp) {
    final d = _devices[fp];
    return d != null && d.isFresh ? d : null;
  }

  /// Called by the server when a device registers with us.
  void add(LsInfo info, String ip) {
    if (info.fingerprint == identity.fingerprint || info.fingerprint.isEmpty) return;
    final existing = _devices[info.fingerprint];
    if (existing != null && existing.ip == ip) {
      existing.lastSeen = DateTime.now();
    } else {
      _devices[info.fingerprint] = LsDevice(info: info, ip: ip, lastSeen: DateTime.now());
    }
    notifyListeners();
  }

  /// Starts listening/announcing; balanced by [stop]. Several screens can
  /// hold it open at once.
  Future<void> start() async {
    _users++;
    if (_socket != null) {
      _announce();
      return;
    }
    await acquireMulticast();
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lsPort,
          // Dart has no SO_REUSEPORT on Android; reuseAddress is enough there.
          reuseAddress: true, reusePort: Platform.isMacOS || Platform.isIOS);
      socket.joinMulticast(InternetAddress(lsMulticastGroup));
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg != null) _onDatagram(dg);
        }
      });
      _socket = socket;
    } catch (e) {
      debugPrint('Multicast unavailable: $e');
    }
    _announce();
    // Re-announce every few seconds while someone is looking.
    _announcer = Timer.periodic(const Duration(seconds: 5), (_) => _announce());
  }

  Future<void> stop() async {
    if (--_users > 0) return;
    _users = 0;
    _announcer?.cancel();
    _announcer = null;
    _socket?.close();
    _socket = null;
    await releaseMulticast();
  }

  void _announce() {
    final msg = utf8.encode(jsonEncode(identity.info(download: true).toJson(announce: true)));
    try {
      _socket?.send(msg, InternetAddress(lsMulticastGroup), lsPort);
    } catch (e) {
      debugPrint('Announce failed: $e');
    }
  }

  Future<void> _onDatagram(Datagram dg) async {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final info = LsInfo.fromJson(json);
    if (info.fingerprint == identity.fingerprint) return;
    final ip = dg.address.address;
    add(info, ip);
    if (json['announce'] == true) {
      // Answer over HTTP first (what LocalSend prefers), UDP as a fallback.
      final device = _devices[info.fingerprint]!;
      final ok = await _register(device);
      if (!ok) {
        _socket?.send(
          utf8.encode(jsonEncode(identity.info(download: true).toJson(announce: false))),
          InternetAddress(lsMulticastGroup),
          lsPort,
        );
      }
    }
  }

  Future<bool> _register(LsDevice device) async {
    final client = lsHttpClient(fingerprint: device.fingerprint, identity: identity.tls);
    try {
      final res = await postJson(client, device.uri('/register'), identity.info(download: true).toJson(),
          timeout: const Duration(seconds: 3));
      return res.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Tries `POST /register` on one address (HTTPS first, then HTTP).
  Future<LsDevice?> probe(String ip, {int port = lsPort}) async {
    for (final scheme in ['https', 'http']) {
      final client = lsHttpClient(identity: identity.tls);
      try {
        final res = await postJson(
          client,
          Uri(scheme: scheme, host: ip, port: port, path: '$lsApi/register'),
          identity.info(download: true).toJson(),
          timeout: const Duration(milliseconds: 1500),
        );
        final json = res.json;
        if (res.ok && json != null) {
          final info = LsInfo.fromJson({...json, 'protocol': scheme, 'port': json['port'] ?? port});
          add(info, ip);
          return _devices[info.fingerprint];
        }
      } catch (_) {
        // Not there, or the other scheme.
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// When multicast is blocked (some routers and hotspots), knock on every
  /// address in our /24 subnet.
  Future<void> scanSubnet() async {
    if (scanning) return;
    final me = await localIp();
    if (me == null) return;
    scanning = true;
    notifyListeners();
    final prefix = me.substring(0, me.lastIndexOf('.') + 1);
    final targets = [
      for (var i = 1; i < 255; i++)
        if ('$prefix$i' != me) '$prefix$i',
    ];
    // 32 at a time keeps the scan to a few seconds without flooding.
    for (var i = 0; i < targets.length; i += 32) {
      await Future.wait([for (final ip in targets.skip(i).take(32)) probe(ip)]);
    }
    scanning = false;
    notifyListeners();
  }
}
