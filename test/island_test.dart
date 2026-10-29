import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/scan/scan_controller.dart';
import 'package:photo_organizer/share/prepare.dart';
import 'package:photo_organizer/share/receive.dart';
import 'package:photo_organizer/share/send_center.dart';
import 'package:photo_organizer/ui/island.dart';

// Stand-ins with just what the island reads; everything else is unused.
class _Receiver extends ChangeNotifier implements Receiver {
  @override
  IncomingRequest? pending;
  @override
  ReceiveSession? session;
  @override
  bool get busy => session != null && !session!.finished;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Sharing extends ChangeNotifier implements SendCenter {
  @override
  final List<SendJob> jobs = [];
  @override
  final _Receiver receiver = _Receiver();
  @override
  void cancelJob(SendJob job) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Controller extends ChangeNotifier implements ScanController {
  @override
  final _Sharing sharing = _Sharing();
  @override
  bool running = false;
  @override
  int total = 0, done = 0;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

SendJob _job() => SendJob(
      id: 1,
      personName: '24 files',
      items: [for (var i = 0; i < 24; i++) SendItem.file('/x/$i.pdf')],
      fingerprint: 'F',
      deviceAlias: 'Maya\'s Pixel 8 Pro',
      quality: SendQuality.original,
    )
      ..status = JobStatus.sending
      ..filesDone = 8
      ..sentBytes = 120 << 20
      ..totalBytes = 312 << 20;

void main() {
  // A phone with a camera hole at the top centre, like a Pixel 7 Pro.
  const phone = MediaQueryData(
    size: Size(412, 915),
    devicePixelRatio: 2,
    viewPadding: EdgeInsets.only(top: 40),
    padding: EdgeInsets.only(top: 40),
    displayFeatures: [
      ui.DisplayFeature(bounds: Rect.fromLTWH(193, 8, 26, 26), type: ui.DisplayFeatureType.cutout, state: ui.DisplayFeatureState.unknown),
    ],
  );

  final cases = <String, void Function(_Controller c)>{
    'sending': (c) => c.sharing.jobs.add(_job()),
    'incoming': (c) => c.sharing.receiver.pending = IncomingRequest('Rahim', [
          for (var i = 0; i < 24; i++) IncomingFile('p$i', 'IMG_$i.jpg', 13 << 20, 'image/jpeg'),
        ], 'Wi-Fi'),
    'receiving': (c) => c.sharing.receiver.session = ReceiveSession(
          's',
          'Rahim\'s iPhone',
          {'p0': IncomingFile('p0', 'a.jpg', 100, 'image/jpeg')},
          {'p0': 't'},
          null,
        )..bytes = 40,
    'scanning': (c) => c
      ..running = true
      ..total = 4812
      ..done = 1204,
  };

  for (final MapEntry(key: name, value: setUp) in cases.entries) {
    testWidgets('island draws while $name', (tester) async {
      tester.view.physicalSize = const Size(824, 1830);
      tester.view.devicePixelRatio = 2;
      final c = _Controller();
      setUp(c);
      final key = GlobalKey();
      await tester.pumpWidget(MediaQuery(
        data: phone,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: RepaintBoundary(
            key: key,
            child: Island(controller: c, child: const ColoredBox(color: Color(0xFF2A1F3D), child: SizedBox.expand())),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
      final out = Platform.environment['ISLAND_OUT'];
      if (out != null) {
        await tester.runAsync(() async {
          final img = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 2);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          File('$out/island_$name.png').writeAsBytesSync(png!.buffer.asUint8List());
        });
      }
    });
  }

  testWidgets('tapping the sending pill expands it', (tester) async {
    final c = _Controller();
    c.sharing.jobs.add(_job());
    await tester.pumpWidget(MediaQuery(
      data: phone,
      child: MaterialApp(home: Island(controller: c, child: const SizedBox.expand())),
    ));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Cancel'), findsNothing);
    await tester.tapAt(const Offset(150, 65));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    // Folds back by itself.
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('quick messages show in the island', (tester) async {
    final c = _Controller();
    await tester.pumpWidget(MediaQuery(
      data: phone,
      child: MaterialApp(home: Island(controller: c, child: const SizedBox.expand())),
    ));
    Island.toast('3 to trash', icon: Icons.delete_outline_rounded, action: 'Undo');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('3 to trash'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('3 to trash'), findsNothing);
  });
}
