import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/desktop_keys.dart';
import 'package:photo_organizer/ui/island.dart' show islandNavigator;

/// An app with a home page and a second page pushed on top.
Future<void> _twoPages(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    navigatorKey: islandNavigator,
    builder: (context, child) => DesktopKeys(child: child!),
    home: const Scaffold(body: Text('home')),
  ));
  islandNavigator.currentState!.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('second'))));
  await tester.pumpAndSettle();
  expect(find.text('second'), findsOneWidget);
}

void main() {
  tearDown(DesktopKeys.escClaims.clear);

  testWidgets('Esc goes back a page', (tester) async {
    await _twoPages(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    // On the first page there is nowhere to go back to.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('Alt + Left goes back a page', (tester) async {
    await _twoPages(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });

  testWidgets("the mouse's Back button goes back a page", (tester) async {
    await _twoPages(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
    await mouse.down(tester.getCenter(find.text('second')));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
  });

  testWidgets('Esc leaves the page alone while something claims it', (tester) async {
    await _twoPages(tester);
    final claim = Object();
    DesktopKeys.escClaims.add(claim);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('Esc closes a dialog, not the page under it', (tester) async {
    await _twoPages(tester);
    showDialog<void>(
      context: islandNavigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsNothing);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('F1 lists the keyboard and touchpad controls', (tester) async {
    await _twoPages(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard and touchpad'), findsOneWidget);
    // The Photos list starts with clicking to select.
    expect(find.text('Select a photo'), findsOneWidget);
    // A second F1 doesn't stack another copy.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard and touchpad'), findsOneWidget);
  });
}
