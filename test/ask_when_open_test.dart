import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/share/discovery.dart';
import 'package:photo_organizer/share/net.dart';
import 'package:photo_organizer/share/prepare.dart';
import 'package:photo_organizer/share/protocol.dart';
import 'package:photo_organizer/share/receive.dart';
import 'package:photo_organizer/share/sender.dart';
import 'package:photo_organizer/share/server.dart';
import 'package:photo_organizer/share/tls.dart';

/// Nothing in these requests touches the database.
class _NoDb implements AppDb {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('with Receive off: asks while the app is open, explains when it is not', (tester) async {
    // Real sockets: widget tests fake every HTTP request otherwise.
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final me = ShareIdentity('Rahim', TlsIdentity.generate());
      final receiver = Receiver(_NoDb())
        ..enabled = false
        ..autoAcceptPaired = false;
      final server = ShareServer(me, Discovery(me), receiver);
      await server.start();
      final tmp = await Directory.systemTemp.createTemp('ask');
      final f = File(p.join(tmp.path, 'trip.pdf'))..writeAsStringSync('pdf');
      final files = [PreparedFile(assetId: 'file:1', fileName: 'trip.pdf', size: 3, mime: 'application/pdf', file: f)];
      final device = LsDevice(
        info: LsInfo(alias: 'Rahim', fingerprint: me.fingerprint, port: me.port, protocol: 'https'),
        ip: '127.0.0.1',
        lastSeen: DateTime.now(),
      );
      final sender = LsSender(ShareIdentity('Maya', TlsIdentity.generate()));

      // 1. App on screen: the question shows up; declining says "declined".
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var questionShown = false;
      receiver.addListener(() {
        final q = receiver.pending;
        if (q == null || q.answered) return;
        questionShown = true;
        q.answer(false);
      });
      final asked = await sender.send(device: device, files: files);
      expect(questionShown, isTrue, reason: 'Accept / Decline must be asked while the app is open');
      expect(asked.outcome, SendOutcome.declined);
      expect(asked.message, 'Rahim declined');

      // 2. App in the background with Receive off: refused, and both sides
      //    are told why.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      questionShown = false;
      final refused = await sender.send(device: device, files: files);
      expect(refused.outcome, SendOutcome.declined);
      expect(refused.message, contains('isn\'t receiving right now'));
      expect(receiver.missed.value?.from, 'Maya');
      expect(questionShown, isFalse);

      await server.stop();
      await tmp.delete(recursive: true);
    });
  });
}
