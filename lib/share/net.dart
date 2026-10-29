import 'dart:io';

import 'package:flutter/services.dart';

import '../data/db.dart';
import 'protocol.dart';
import 'tls.dart';

const _multicast = MethodChannel('photo_organizer/multicast');

/// Android ignores Wi-Fi multicast unless the app holds a lock.
Future<void> acquireMulticast() async {
  try {
    await _multicast.invokeMethod('acquire');
  } catch (_) {}
}

Future<void> releaseMulticast() async {
  try {
    await _multicast.invokeMethod('release');
  } catch (_) {}
}

/// This phone's address on the local network: Wi-Fi first, then its own
/// hotspot, then anything private. Null when offline.
Future<String?> localIp() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  String? best;
  var bestScore = -1;
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (a.isLoopback) continue;
      final ip = a.address;
      final private = ip.startsWith('192.168.') ||
          ip.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
      final name = i.name.toLowerCase();
      final score = (private ? 10 : 0) +
          (name.startsWith('wlan') ? 5 : 0) +
          (name.contains('ap') || name.startsWith('swlan') ? 3 : 0) -
          (name.startsWith('rmnet') ? 20 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = ip;
      }
    }
  }
  return best;
}

/// Who we are to other LocalSend devices: a name, and the fingerprint of
/// our own HTTPS certificate (see [TlsIdentity]).
class ShareIdentity {
  ShareIdentity(this.alias, this.tls);

  final String alias;
  final TlsIdentity tls;

  /// Port our HTTPS server ended up on (53317 unless that was taken).
  int port = lsPort;

  String get fingerprint => tls.fingerprint;

  static const _aliasKey = 'share_alias';

  static Future<ShareIdentity> load(AppDb db) async {
    final alias = await db.setting(_aliasKey) ?? 'ShareBro';
    return ShareIdentity(alias, await TlsIdentity.load(db));
  }

  static Future<void> setAlias(AppDb db, String alias) =>
      db.setSetting(_aliasKey, alias.trim().isEmpty ? 'ShareBro' : alias.trim());

  LsInfo info({bool download = false}) => LsInfo(
        alias: alias,
        fingerprint: fingerprint,
        deviceModel: 'ShareBro',
        deviceType: LsDeviceType.mobile,
        port: port,
        protocol: 'https',
        download: download,
      );
}
