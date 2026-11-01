import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/data/group_match.dart';
import 'package:photo_organizer/data/profile.dart';
import 'package:photo_organizer/share/discovery.dart';
import 'package:photo_organizer/share/group.dart';
import 'package:photo_organizer/share/net.dart';
import 'package:photo_organizer/share/protocol.dart';
import 'package:photo_organizer/share/receive.dart';
import 'package:photo_organizer/share/server.dart';
import 'package:photo_organizer/share/tls.dart';

/// Nothing in these requests touches the database.
class _NoDb implements AppDb {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A unit vector mostly along [axis], nudged by [noise] toward [toward].
Float32List face(int axis, {int toward = 0, double noise = 0}) {
  final v = Float32List(16);
  v[axis] = 1;
  v[toward] += noise;
  final n = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
  for (var i = 0; i < v.length; i++) {
    v[i] /= n;
  }
  return v;
}

void main() {
  test('each photo goes only to the members in it; you and strangers are left out', () {
    final plan = planGroup(GroupPlanInput(
      {'me': [face(0)], 'maya': [face(1)], 'leo': [face(2)]},
      'me',
      ['a', 'b', 'c', 'd', 'e'],
      {
        'a': [PhotoFace('a', face(1, noise: .1), null), PhotoFace('a', face(2), null)],
        'b': [PhotoFace('b', face(0), null)], // only you
        'c': [PhotoFace('c', face(9), null)], // a stranger
        'd': [PhotoFace('d', face(1), null), PhotoFace('d', face(0), null)],
        // Leo in sunglasses: a weaker match, asked about.
        'e': [PhotoFace('e', face(2, toward: 9, noise: 1.1), null)],
      },
      0.8,
      0.6,
    ));
    expect(plan.send, {'maya': ['a', 'd'], 'leo': ['a']});
    expect([for (final u in plan.unsure) (u.assetId, u.member)], [('e', 'leo')]);
    expect(plan.stay, 2); // b and c
    plan.accept(plan.unsure.single);
    expect(plan.send['leo'], ['a', 'e']);
    expect(plan.copies, 4);
  });

  test('a face profile survives saving as text', () {
    final p = FaceProfile(faces: [face(3), face(4)], thumb: Uint8List.fromList([1, 2, 3]), source: FaceSource.upload);
    final back = FaceProfile.fromJson(p.toJson());
    expect(back.faces, hasLength(2));
    expect(back.faces[1], face(4));
    expect(back.thumb, [1, 2, 3]);
    expect(back.source, FaceSource.upload);
    expect(p.adding([for (var i = 0; i < 30; i++) face(5)]).faces, hasLength(FaceProfile.maxFaces));
  });

  testWidgets('phones start, join and leave a trip group', (tester) async {
    // Real sockets: widget tests fake every HTTP request otherwise.
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      // Only the host serves: in one test process both servers would share
      // the port and answer each other's requests.
      Future<(ShareServer, GroupHub)> phone(String name, int axis, {bool serve = true}) async {
        final me = ShareIdentity(name, TlsIdentity.generate());
        final server = ShareServer(me, Discovery(me), Receiver(_NoDb()));
        final hub = GroupHub(me, server.discovery, open: () async {}, close: () async {})
          ..profile = () => FaceProfile(faces: [face(axis)]);
        server.groups = hub;
        if (serve) await server.start();
        return (server, hub);
      }

      final (hostServer, host) = await phone('Maya\'s Pixel', 1);
      final (guestServer, guest) = await phone('Leo\'s Galaxy', 2, serve: false);
      final g = await host.create('Goa trip');
      final near = NearbyGroup(
        g.id,
        g.name,
        'Maya\'s Pixel',
        1,
        LsDevice(
          info: LsInfo(alias: 'Maya\'s Pixel', fingerprint: host.identity.fingerprint, port: host.identity.port, protocol: 'https'),
          ip: '127.0.0.1',
          lastSeen: DateTime.now(),
        ),
      );

      expect(await guest.join(near, '0000' == g.code ? '1111' : '0000'), 'That code isn\'t right.');
      expect(guest.group, isNull);

      expect(await guest.join(near, g.code), isNull);
      expect(guest.group!.name, 'Goa trip');
      expect(guest.group!.members.keys, containsAll([host.identity.fingerprint, guest.identity.fingerprint]));
      expect(g.members[guest.identity.fingerprint]!.faces.single, face(2));
      // Each trusts the other's sends, not strangers'.
      expect(host.trusts(guest.identity.fingerprint), isTrue);
      expect(guest.trusts(host.identity.fingerprint.toUpperCase()), isTrue);
      expect(host.trusts('f' * 64), isFalse);

      await guest.leave();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(g.members.keys, [host.identity.fingerprint]);
      expect(host.trusts(guest.identity.fingerprint), isFalse);

      await host.leave();
      await hostServer.stop();
      await guestServer.stop();
    });
  });
}
