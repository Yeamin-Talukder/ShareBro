import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/update_sheet.dart';
import 'package:photo_organizer/update/release.dart';
import 'package:photo_organizer/update/updater.dart';

const _body = '''**ShareBro 1.5.0** adds memories and faster scans. It installs over v1.4.0.

## Which file do I download?

| File | For |
|---|---|
| **`ShareBro-v1.5.0-arm64-v8a.apk`** | **Almost every phone.** |

## What's new

- **Memories.** A "this day last year" card on *People*.
- **Faster scans:** about 30% faster on big albums, see [the notes](https://example.com).
- Fixes for sending to `LocalSend` on Windows

## Notes

- **Checksums:** `SHA256SUMS.txt` lists checksums.
''';

Map<String, Object?> _json({String tag = 'v1.5.0'}) => {
      'tag_name': tag,
      'body': _body,
      'published_at': '2026-11-09T10:00:00Z',
      'html_url': 'https://github.com/Yeamin-Talukder/ShareBro/releases/tag/$tag',
      'assets': [
        {'name': 'SHA256SUMS.txt', 'browser_download_url': 'https://x/SHA256SUMS.txt', 'size': 287},
        {'name': 'ShareBro-$tag-arm64-v8a.apk', 'browser_download_url': 'https://x/arm64.apk', 'size': 99155943},
        {'name': 'ShareBro-$tag-armeabi-v7a.apk', 'browser_download_url': 'https://x/v7a.apk', 'size': 87544935},
        {'name': 'ShareBro-$tag-x86_64.apk', 'browser_download_url': 'https://x/x86.apk', 'size': 105017735},
      ],
    };

void main() {
  group('Version', () {
    test('reads tags and build numbers', () {
      expect(Version.tryParse('v1.5.0').toString(), '1.5.0');
      expect(Version.tryParse('1.4.0+7').toString(), '1.4.0');
      expect(Version.tryParse('ShareBro 2.0').toString(), '2.0');
      expect(Version.tryParse('latest'), isNull);
    });

    test('compares number by number', () {
      Version v(String s) => Version.tryParse(s)!;
      expect(v('1.5.0') > v('1.4.0'), isTrue);
      expect(v('1.10.0') > v('1.9.3'), isTrue);
      expect(v('2.0') > v('1.99.99'), isTrue);
      expect(v('1.4.0') > v('1.4.0'), isFalse);
      expect(v('1.4') == v('1.4.0'), isTrue);
      expect(v('1.4').hashCode, v('1.4.0').hashCode);
    });
  });

  group('Release', () {
    final r = Release.fromGitHub(_json());

    test('reads the GitHub release', () {
      expect(r.version.toString(), '1.5.0');
      expect(r.published, DateTime.utc(2026, 11, 9, 10));
      expect(r.checksums?.name, 'SHA256SUMS.txt');
      expect(r.summary, 'ShareBro 1.5.0 adds memories and faster scans. It installs over v1.4.0.');
    });

    test('picks the APK for the phone', () {
      expect(r.apkFor(['arm64-v8a', 'armeabi-v7a', 'armeabi'])?.url, 'https://x/arm64.apk');
      expect(r.apkFor(['armeabi-v7a', 'armeabi'])?.url, 'https://x/v7a.apk');
      expect(r.apkFor(['x86_64', 'x86'])?.url, 'https://x/x86.apk');
      expect(r.apkFor(['mips']), isNull);
    });

    test('falls back to a universal APK', () {
      final u = Release.fromGitHub({
        'tag_name': 'v2.0.0',
        'assets': [
          {'name': 'ShareBro-v2.0.0.apk', 'browser_download_url': 'https://x/all.apk', 'size': 1},
        ],
      });
      expect(u.apkFor(['arm64-v8a'])?.url, 'https://x/all.apk');
    });

    test('takes only "What\'s new" points, without Markdown', () {
      expect(r.notes.map((n) => n.title), ['Memories', 'Faster scans', '']);
      expect(r.notes[0].text, 'A "this day last year" card on People.');
      expect(r.notes[1].text, 'about 30% faster on big albums, see the notes.');
      expect(r.notes[2].text, 'Fixes for sending to LocalSend on Windows');
    });

    test('uses every bullet when there is no "What\'s new"', () {
      final notes = parseNotes('Changes:\n\n* One\n* **Two** more\n');
      expect(notes.map((n) => n.toString()), ['One', 'Two: more']);
    });
  });

  test('reads SHA256SUMS.txt', () {
    final a = 'a' * 64, b = 'B' * 64;
    final sums = parseSums('$a  ShareBro-v1.5.0-arm64-v8a.apk\n$b *dist/ShareBro-v1.5.0-x86_64.apk\nnot a line\n');
    expect(sums, {'ShareBro-v1.5.0-arm64-v8a.apk': a, 'ShareBro-v1.5.0-x86_64.apk': 'b' * 64});
  });

  test('says when a release came out', () {
    final now = DateTime(2026, 11, 11, 9);
    expect(releasedAgo(DateTime(2026, 11, 11, 1), now), 'today');
    expect(releasedAgo(DateTime(2026, 11, 10, 23), now), 'yesterday');
    expect(releasedAgo(DateTime(2026, 11, 9), now), '2 days ago');
    expect(releasedAgo(DateTime(2026, 10, 20), now), '3 weeks ago');
    expect(releasedAgo(DateTime(2026, 3, 2), now), 'Mar 2026');
    expect(shortAbi('ShareBro-v1.5.0-arm64-v8a.apk'), 'arm64');
  });

  group('Update sheet', () {
    final u = Updater.instance;

    setUp(() {
      u.current = Version.tryParse('1.4.0')!;
      u.release = Release.fromGitHub(_json());
      u.apk = u.release!.apkFor(['arm64-v8a']);
    });

    tearDown(() {
      u.stage = UpdateStage.idle;
      u.release = null;
      u.apk = null;
      u.received = 0;
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => showUpdateSheet(context), child: const Text('open')),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('shows what\'s new with Update, Later and Skip', (tester) async {
      u.stage = UpdateStage.available;
      await open(tester);
      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('1.5.0'), findsOneWidget);
      expect(find.textContaining('Memories', findRichText: true), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
      expect(find.text('Skip this version'), findsOneWidget);
    });

    testWidgets('shows download progress', (tester) async {
      u.stage = UpdateStage.downloading;
      u.received = 99155943 ~/ 2;
      await open(tester);
      expect(find.text('Downloading…'), findsOneWidget);
      expect(find.text('47.3 MB of 94.6 MB'), findsOneWidget);
      expect(find.text('Cancel download'), findsOneWidget);
    });

    testWidgets('says it\'s verified and offers Install', (tester) async {
      u.stage = UpdateStage.ready;
      u.checksumVerified = true;
      await open(tester);
      expect(find.text('Ready to install'), findsOneWidget);
      expect(find.text('Verified: matches ShareBro 1.5.0 on GitHub'), findsOneWidget);
      expect(find.text('Install update'), findsOneWidget);
    });

    testWidgets('a dropped download offers Retry', (tester) async {
      u.stage = UpdateStage.failed;
      u.received = 1000;
      u.error = 'The connection dropped at 1000 B. Retry picks up where it stopped.';
      await open(tester);
      expect(find.text('Download paused'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('up to date', (tester) async {
      u.release = null;
      u.apk = null;
      u.stage = UpdateStage.upToDate;
      await open(tester);
      expect(find.text("You're up to date"), findsOneWidget);
      expect(find.textContaining('ShareBro 1.4.0 is the latest version'), findsOneWidget);
    });
  });
}
