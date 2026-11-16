// A walk through the desktop layout in the real Windows app, for checking it
// by eye: scans a folder, then opens each page and waits while the window is
// captured from outside.
//
//   flutter test integration_test/desktop_tour_test.dart -d windows
//     --dart-define=TOUR_PHOTOS=<folder of photos>
//     --dart-define=TOUR_SIGNALS=<empty folder>
//
// At each stop it writes "<step>.ready" into TOUR_SIGNALS and waits for
// "<step>.go" (or 90 s). Uses the app's real data folder: back it up first.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/main.dart' as app;
import 'package:photo_organizer/ui/root_screen.dart';

const _photos = String.fromEnvironment('TOUR_PHOTOS');
const _signals = String.fromEnvironment('TOUR_SIGNALS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop tour', (tester) async {
    Future<void> wait(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> stop(String step) async {
      await wait(const Duration(seconds: 2));
      await File(p.join(_signals, '$step.ready')).writeAsString('');
      final go = File(p.join(_signals, '$step.go'));
      final end = DateTime.now().add(const Duration(seconds: 90));
      while (!go.existsSync() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> tapText(String text) async {
      await tester.tap(find.text(text).first);
      await wait(const Duration(milliseconds: 800));
    }

    await tester.runAsync(() => app.main());
    await wait(const Duration(seconds: 6));
    final c = tester.widget<RootScreen>(find.byType(RootScreen)).controller;

    await stop('empty');
    await tester.runAsync(() => c.scanDesktopFolder(_photos));
    await wait(const Duration(seconds: 4));
    await stop('scanning');
    final end = DateTime.now().add(const Duration(minutes: 6));
    while (c.running && DateTime.now().isBefore(end)) {
      await wait(const Duration(seconds: 1));
    }
    await wait(const Duration(seconds: 4));
    await stop('people');

    await tapText('Photos');
    await stop('photos');

    // The first photo in the grid, below the toolbar and the day header.
    final grid = tester.getRect(find.byType(RootScreen));
    await tester.tapAt(Offset(grid.left + 400, grid.top + 200));
    await wait(const Duration(seconds: 2));
    await stop('viewer');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await wait(const Duration(seconds: 1));
    await stop('viewer2');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await wait(const Duration(seconds: 1));

    await tapText('Explore');
    await stop('explore');
    await tapText('Send & receive');
    await stop('share');
    await tapText(p.basename(_photos));
    await stop('folder');
    await tapText('People');
    await stop('narrow');
  });
}
