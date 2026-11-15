import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/anim.dart';
import 'package:photo_organizer/ui/permission_explainer.dart';
import 'package:photo_organizer/ui/sections.dart';

double _opacity(WidgetTester tester) =>
    tester.widget<FadeTransition>(find.byType(FadeTransition).first).opacity.value;

void main() {
  testWidgets('entrances play normally', (tester) async {
    await tester.pumpWidget(const Text('hi', textDirection: TextDirection.ltr)
        .animate()
        .fadeIn(duration: const Duration(seconds: 1)));
    expect(_opacity(tester), 0);
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
  });

  testWidgets('with Remove animations on, entrances show their end at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures.allOn;
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    var looped = false;
    var done = 0;
    await tester.pumpWidget(const Text('hi', textDirection: TextDirection.ltr)
        .animate(onPlay: (c) => looped = true, onComplete: (_) => done++)
        .fadeIn(delay: const Duration(seconds: 1), duration: const Duration(seconds: 1)));
    await tester.pump();
    expect(_opacity(tester), 1);
    expect(looped, isFalse, reason: 'repeating animations stay still');
    expect(done, 1, reason: 'code waiting for the end still runs');
    await tester.pump(const Duration(milliseconds: 10));
  });

  testWidgets('boxes holding text grow with the font size setting', (tester) async {
    late double normal, large;
    Widget probe(double scale, void Function(double) out) => MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Builder(builder: (context) {
            out(textHeight(context, 36));
            return const SizedBox();
          }),
        );
    await tester.pumpWidget(probe(1, (h) => normal = h));
    await tester.pumpWidget(probe(2, (h) => large = h));
    expect(normal, 36);
    expect(large, 72);
  });

  testWidgets('the permission explainer has exactly one button', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PermissionExplainer(
          icon: Icons.photo_library_rounded,
          title: photoTitle,
          body: photoBody,
          onContinue: () => tapped = true,
        ),
      ),
    ));
    expect(find.byWidgetPredicate((w) => w is ButtonStyleButton), findsOneWidget);
    await tester.tap(find.text('Continue'));
    expect(tapped, isTrue);
  });
}
