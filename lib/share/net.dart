import 'dart:io';

import 'package:flutter/services.dart';

import '../data/db.dart';
import 'protocol.dart';
import 'tls.dart';
import '../platform/device.dart';

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

/// A local network this device is on: its address there and the interface.
typedef LanAddress = ({InternetAddress address, NetworkInterface interface});

/// Every local network this device is on (private IPv4 addresses): Wi-Fi,
/// the phone's own hotspot, a computer's Wi-Fi or cable. Not mobile data
/// or loopback. A phone sharing its hotspot is on two at once (mobile data
/// out, the hotspot in), and finding devices has to use the hotspot one.
Future<List<LanAddress>> lanAddresses() async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } catch (_) {
    return const [];
  }
  return [
    for (final i in interfaces)
      if (!i.name.toLowerCase().startsWith('rmnet'))
        for (final a in i.addresses)
          if (!a.isLoopback && _isPrivate(a.address)) (address: a, interface: i),
  ];
}

bool _isPrivate(String ip) =>
    ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);

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
      final private = _isPrivate(ip);
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
        // Computers show as computers in LocalSend and in ShareBro's lists.
        deviceType: Device.desktop ? LsDeviceType.desktop : LsDeviceType.mobile,
        port: port,
        protocol: 'https',
        download: download,
      );
}
