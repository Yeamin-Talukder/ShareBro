import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/launch_clink.dart';

void main() {
  Future<void> play(WidgetTester tester, {required bool motion}) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(400, 800), disableAnimations: !motion),
        child: Stack(children: [LaunchClink(onDone: () => done = true)]),
      ),
    ));
    // Every frame of the fall, the clink and the name, then the fade.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(find.text('B'), findsOneWidget);
    expect(done, isTrue);
  }

  testWidgets('the clink plays through and hands over', (tester) => play(tester, motion: true));

  testWidgets('with motion off it shows the logo and moves on', (tester) => play(tester, motion: false));
}
