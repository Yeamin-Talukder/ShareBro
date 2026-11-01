import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/profile.dart';
import '../scan/background.dart';
import 'client.dart';
import 'discovery.dart';
import 'net.dart';
import 'protocol.dart';

/// ShareBro's own API next to LocalSend's, on the same HTTPS server.
const groupApi = '/api/sharebro/v1/groups';

/// How often members ask the host who else has joined.
const _syncEvery = Duration(seconds: 6);

/// One phone in a trip group: who owns it, how to reach it, and the
/// owner's face (fingerprints only).
class GroupMember {
  GroupMember({
    required this.fingerprint,
    required this.alias,
    required this.faces,
    this.thumb,
    this.ip,
    this.port = lsPort,
  });

  final String fingerprint;
  String alias;
  List<Float32List> faces;
  Uint8List? thumb;
  String? ip;
  int port;

  /// A stand-in LocalSend device for sending to this member.
  LsDevice get device => LsDevice(
        info: LsInfo(alias: alias, fingerprint: fingerprint, port: port, protocol: 'https', deviceModel: 'ShareBro'),
        ip: ip ?? '',
        lastSeen: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'alias': alias,
        'faces': [for (final f in faces) encodeFace(f)],
        'thumb': thumb == null ? null : base64Encode(thumb!),
        'ip': ip,
        'port': port,
      };

  static GroupMember fromJson(Map<String, dynamic> j) => GroupMember(
        fingerprint: j['fingerprint'] as String,
        alias: j['alias'] as String? ?? 'ShareBro',
        faces: [for (final f in (j['faces'] as List? ?? const [])) decodeFace(f as String)],
        thumb: j['thumb'] == null ? null : base64Decode(j['thumb'] as String),
        ip: j['ip'] as String?,
        port: (j['port'] as num?)?.toInt() ?? lsPort,
      );
}

/// A trip group: everyone's phone, so photos can go to the people in them.
class TripGroup {
  TripGroup({required this.id, required this.name, required this.code, required this.hostFingerprint, required this.hosting});

  final String id;
  final String name;

  /// Four digits the host shows; joining needs it.
  final String code;
  final String hostFingerprint;

  /// True on the phone that started the group.
  final bool hosting;

  /// Fingerprint -> member, the host first.
  final Map<String, GroupMember> members = {};

  /// Where the host is, for members.
  GroupMember? get host => members[hostFingerprint];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': hostFingerprint,
        'members': [for (final m in members.values) m.toJson()],
      };
}

/// A group someone nearby has started.
class NearbyGroup {
  NearbyGroup(this.id, this.name, this.hostAlias, this.count, this.host);

  final String id, name, hostAlias;
  final int count;
  final LsDevice host;
}

/// Starting, finding and joining trip groups, and keeping everyone's member
/// list in step. One group at a time; it lasts until it's left or ended
/// (or the app is closed).
class GroupHub extends ChangeNotifier {
  GroupHub(this.identity, this.discovery, {required this.open, required this.close});

  final ShareIdentity identity;
  final Discovery discovery;

  /// Keep discovery and the server running while in a group.
  final Future<void> Function() open, close;

  /// Your profile, for your member card.
  FaceProfile Function() profile = () => FaceProfile(faces: const []);

  TripGroup? group;
  List<NearbyGroup> nearby = [];
  bool searching = false;

  /// Set when the host ended the group or it can't be reached any more.
  String? ended;
  Timer? _sync;

  GroupMember _me() => GroupMember(
        fingerprint: identity.fingerprint,
        alias: identity.alias,
        faces: profile().faces,
        thumb: profile().thumb,
        port: identity.port,
      );

  /// Whether [fingerprint] is a phone in your group (their sends are
  /// accepted without asking).
  bool trusts(String fingerprint) =>
      group?.members.keys.any((k) => k.toLowerCase() == fingerprint.toLowerCase() && k != identity.fingerprint) ??
      false;

  Future<TripGroup> create(String name) async {
    await leave();
    await open();
    final r = math.Random.secure();
    final g = TripGroup(
      id: List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join(),
      name: name.trim().isEmpty ? 'Trip' : name.trim(),
      code: (1000 + r.nextInt(9000)).toString(),
      hostFingerprint: identity.fingerprint,
      hosting: true,
    );
    g.members[identity.fingerprint] = _me();
    group = g;
    ended = null;
    await KeepAlive.hold('group', 'Trip group open', '${g.name} · code ${g.code}');
    notifyListeners();
    return g;
  }

  /// Asks every ShareBro phone around for the groups it hosts.
  Future<void> search() async {
    if (searching) return;
    searching = true;
    notifyListeners();
    try {
      await open();
      // Give announcements a moment to come back.
      if (discovery.devices.isEmpty) await Future<void>.delayed(const Duration(seconds: 2));
      final found = <NearbyGroup>[];
      await Future.wait([
        for (final d in discovery.devices)
          _post(d.ip, d.info.port, '', const {}).then((res) {
            for (final g in (res?.json?['groups'] as List? ?? const [])) {
              final m = (g as Map).cast<String, dynamic>();
              found.add(NearbyGroup(m['id'] as String, m['name'] as String, d.alias, (m['count'] as num).toInt(), d));
            }
          }),
      ]);
      nearby = found;
    } finally {
      searching = false;
      notifyListeners();
      await close();
    }
  }

  /// Joins [g] with the code its host shows. Returns why it didn't work,
  /// or null when you're in.
  Future<String?> join(NearbyGroup g, String code) async {
    await leave();
    await open();
    final res = await _post(g.host.ip, g.host.info.port, '/join', {'id': g.id, 'code': code.trim(), 'member': _me().toJson()});
    if (res == null) {
      await close();
      return 'Couldn\'t reach ${g.hostAlias}. Stay on the same Wi‑Fi or hotspot and try again.';
    }
    if (res.status == HttpStatus.unauthorized) {
      await close();
      return 'That code isn\'t right.';
    }
    if (!res.ok || res.json == null) {
      await close();
      return 'That group has ended.';
    }
    final group = _fromJson(res.json!, code.trim(), hostIp: g.host.ip);
    this.group = group;
    ended = null;
    await KeepAlive.hold('group', 'In a trip group', group.name);
    _sync = Timer.periodic(_syncEvery, (_) => _syncNow());
    notifyListeners();
    return null;
  }

  /// Leaves (or, for the host, ends) the group.
  Future<void> leave() async {
    final g = group;
    if (g == null) return;
    _sync?.cancel();
    _sync = null;
    group = null;
    notifyListeners();
    await KeepAlive.release('group');
    if (!g.hosting) {
      final host = g.host;
      if (host?.ip != null) {
        unawaited(_post(host!.ip!, host.port, '/leave', {'id': g.id, 'code': g.code, 'fingerprint': identity.fingerprint}));
      }
    }
    await close();
  }

  /// Your profile changed: the group gets your new card on the next sync.
  void refreshMe() {
    final g = group;
    if (g == null) return;
    g.members[identity.fingerprint] = _me()..ip = g.members[identity.fingerprint]?.ip;
    notifyListeners();
    if (!g.hosting) _syncNow();
  }

  Future<void> _syncNow() async {
    final g = group;
    final host = g?.host;
    if (g == null || g.hosting || host?.ip == null) return;
    final res = await _post(host!.ip!, host.port, '/sync', {'id': g.id, 'code': g.code, 'member': _me().toJson()});
    if (group != g) return;
    if (res == null) return; // Out of range for now; try again next time.
    if (!res.ok || res.json == null) {
      ended = 'The group "${g.name}" has ended.';
      await leave();
      return;
    }
    final fresh = _fromJson(res.json!, g.code, hostIp: host.ip!);
    g.members
      ..clear()
      ..addAll(fresh.members);
    notifyListeners();
  }

  TripGroup _fromJson(Map<String, dynamic> j, String code, {required String hostIp}) {
    final g = TripGroup(
      id: j['id'] as String,
      name: j['name'] as String,
      code: code,
      hostFingerprint: j['host'] as String,
      hosting: false,
    );
    for (final m in (j['members'] as List)) {
      final member = GroupMember.fromJson((m as Map).cast<String, dynamic>());
      // The host doesn't see its own address; we know it.
      if (member.fingerprint == g.hostFingerprint) member.ip = hostIp;
      g.members[member.fingerprint] = member;
    }
    return g;
  }

  Future<LsResponse?> _post(String ip, int port, String path, Map<String, dynamic> body) async {
    final client = lsHttpClient(identity: identity.tls);
    try {
      return await postJson(client, Uri(scheme: 'https', host: ip, port: port, path: '$groupApi$path'), body,
          timeout: const Duration(seconds: 5));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // ---- Server side (the host) ----

  /// Answers ShareBro group requests. Returns false for anything else.
  Future<bool> handle(HttpRequest req, String? ip) async {
    final path = req.uri.path;
    if (req.method != 'POST' || !path.startsWith(groupApi)) return false;
    final res = req.response;
    Map<String, dynamic> body;
    try {
      final text = await utf8.decodeStream(req);
      body = text.isEmpty ? {} : (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return _reply(res, HttpStatus.badRequest);
    }
    final g = group;
    if (path == groupApi) {
      return _reply(res, HttpStatus.ok, {
        'groups': [
          if (g != null && g.hosting) {'id': g.id, 'name': g.name, 'count': g.members.length},
        ],
      });
    }
    if (g == null || !g.hosting || body['id'] != g.id) return _reply(res, HttpStatus.notFound);
    if (body['code'] != g.code) return _reply(res, HttpStatus.unauthorized);
    switch (path.substring(groupApi.length)) {
      case '/join' || '/sync':
        final card = body['member'];
        if (card is! Map) return _reply(res, HttpStatus.badRequest);
        final m = GroupMember.fromJson(card.cast<String, dynamic>())..ip = ip;
        if (m.fingerprint == identity.fingerprint) return _reply(res, HttpStatus.badRequest);
        // A sync from someone who left (or was never in) doesn't sneak back in.
        if (path.endsWith('/sync') && !g.members.containsKey(m.fingerprint)) return _reply(res, HttpStatus.notFound);
        final isNew = !g.members.containsKey(m.fingerprint);
        g.members[m.fingerprint] = m;
        g.members[identity.fingerprint] = _me();
        if (isNew) {
          unawaited(KeepAlive.hold('group', 'Trip group open', '${g.name} · ${g.members.length} phones'));
        }
        notifyListeners();
        return _reply(res, HttpStatus.ok, g.toJson());
      case '/leave':
        g.members.remove(body['fingerprint']);
        notifyListeners();
        return _reply(res, HttpStatus.ok);
      default:
        return _reply(res, HttpStatus.notFound);
    }
  }

  Future<bool> _reply(HttpResponse res, int status, [Object? json]) async {
    res.statusCode = status;
    if (json != null) {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(json));
    }
    await res.close();
    return true;
  }

  @override
  void dispose() {
    _sync?.cancel();
    super.dispose();
  }
}
