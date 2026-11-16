import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/platform/device.dart';
import 'package:photo_organizer/ui/desktop_layout.dart';
import 'package:photo_organizer/ui/glass.dart';

/// Builds [child] in a window [width] wide and hands back its padding.
Future<EdgeInsets> _padIn(WidgetTester tester, double width) async {
  late EdgeInsets out;
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(size: Size(width, 800)),
    child: Builder(builder: (context) {
      out = DesktopLayout.pad(context, const EdgeInsets.fromLTRB(16, 8, 16, 32));
      return const SizedBox();
    }),
  ));
  return out;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('on a phone, pages keep their own padding', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await _padIn(tester, 1600), const EdgeInsets.fromLTRB(16, 8, 16, 32));
    expect(Device.noun, 'phone');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on a computer, a wide window centres a readable column', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final pad = await _padIn(tester, 1600);
    // 1600 wide, 860 of content: 370 on each side, plus the page's own 16.
    expect(pad.left, 16 + 370);
    expect(pad.right, 16 + 370);
    expect(pad.top, 8);
    expect(pad.bottom, 32);
    expect(Device.noun, 'computer');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on a computer, a narrow window adds nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await _padIn(tester, 800), const EdgeInsets.fromLTRB(16, 8, 16, 32));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a page of rows stays readable in a wide window', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GlassScrollView(
          title: 'Page',
          maxContentWidth: DesktopLayout.pageWidth,
          slivers: [
            SliverToBoxAdapter(child: Container(key: const Key('row'), height: 40, color: Colors.red)),
          ],
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('row'))).width, DesktopLayout.pageWidth);
    debugDefaultTargetPlatformOverride = null;
  });
}
