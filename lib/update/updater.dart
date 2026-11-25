import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:path_provider/path_provider.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../platform/device.dart';
import '../share/notify.dart';
import 'release.dart';
import 'windows_version.dart';

enum UpdateStage { idle, checking, upToDate, available, downloading, verifying, ready, failed }

/// What [Updater.install] did.
enum InstallResult { started, needsPermission, failed }

/// Updates ShareBro from inside the app: asks GitHub for the latest release
/// once a day, shows what's new, downloads the APK built for this phone
/// (picking up where it stopped if the connection drops), checks it against
/// the release's SHA256SUMS.txt, and hands it to Android's installer.
///
/// On Windows the same steps fetch the newest release that has a Windows
/// installer (those are tagged "vX.Y.Z-windows" and marked pre-release, so
/// they never reach phones), then run it quietly: it closes ShareBro,
/// updates it in place and opens it again.
class Updater extends ChangeNotifier {
  Updater._();

  static final instance = Updater._();

  static const repo = 'Yeamin-Talukder/ShareBro';
  static const _latest = 'https://api.github.com/repos/$repo/releases/latest';
  static const _recent = 'https://api.github.com/repos/$repo/releases?per_page=20';
  static const _channel = MethodChannel('photo_organizer/update');
  static const _notifyId = 5000;

  static const _autoKey = 'update_auto';
  static const _wifiKey = 'update_wifi';
  static const _skipKey = 'update_skip';
  static const _lastKey = 'update_last';
  static const _announcedKey = 'update_announced';
  static const _installingKey = 'update_installing';

  AppDb? _db;

  /// This app's version, from Android ("1.4.0").
  Version current = Version([0]);
  String get currentText => current.toString();

  /// The phone's CPU types, best first ("arm64-v8a").
  List<String> abis = const ['arm64-v8a'];

  bool autoCheck = true;

  /// On mobile data, ask before downloading.
  bool wifiOnly = true;

  UpdateStage stage = UpdateStage.idle;
  Release? release;

  /// The file that installs [release] here: the APK built for this phone,
  /// or the Windows installer.
  ReleaseAsset? apk;
  DateTime? checkedAt;

  /// Bytes of [apk] on the phone so far, and bytes per second.
  int received = 0;
  double? speed;

  /// What went wrong, in words for people.
  String? error;

  /// The last download didn't match the release, so it was deleted.
  bool badFile = false;

  /// True when the file matched the release's checksum (not just its size).
  bool checksumVerified = false;

  /// Version just installed over the old one: say welcome once.
  String? welcome;

  /// A new version found by the daily check, to show a banner for.
  final announcements = StreamController<Release>.broadcast();

  String? _skipped;
  File? _file;
  HttpClient? _client;
  bool _cancelled = false;

  bool get busy => stage == UpdateStage.checking || stage == UpdateStage.downloading || stage == UpdateStage.verifying;

  /// There's a newer version waiting for the person (the badge in Settings).
  bool get hasUpdate =>
      release != null &&
      const {UpdateStage.available, UpdateStage.downloading, UpdateStage.verifying, UpdateStage.ready}.contains(stage);

  double get progress => apk == null || apk!.size == 0 ? 0 : (received / apk!.size).clamp(0, 1);

  /// Time left at the current speed.
  Duration? get remaining {
    final s = speed, a = apk;
    if (s == null || s <= 0 || a == null) return null;
    return Duration(seconds: ((a.size - received) / s).ceil());
  }

  Future<void> load(AppDb db) async {
    _db = db;
    autoCheck = await db.setting(_autoKey) != '0';
    wifiOnly = await db.setting(_wifiKey) != '0';
    _skipped = await db.setting(_skipKey);
    checkedAt = DateTime.tryParse(await db.setting(_lastKey) ?? '');
    try {
      final info = (await _channel.invokeMapMethod<String, Object?>('info')) ?? const {};
      current = Version.tryParse(info['version'] as String? ?? '') ?? current;
      final a = (info['abis'] as List?)?.cast<String>();
      if (a != null && a.isNotEmpty) abis = a;
    } on MissingPluginException {
      // Not on Android: Windows stamps the version into the .exe.
      final v = windowsAppVersion();
      if (v != null) current = Version.tryParse(v) ?? current;
    } on PlatformException {
      // Keep the defaults.
    }
    // Back after an update: say so once, and clear the downloaded file.
    final installing = await db.setting(_installingKey);
    if (installing != null && installing.isNotEmpty) {
      final v = Version.tryParse(installing);
      if (v != null && !(v > current)) {
        welcome = currentText;
        await db.setSetting(_installingKey, '');
        unawaited(_clearDownloads());
      }
    }
  }

  Future<void> setAutoCheck(bool on) async {
    autoCheck = on;
    notifyListeners();
    await _db?.setSetting(_autoKey, on ? '1' : '0');
  }

  Future<void> setWifiOnly(bool on) async {
    wifiOnly = on;
    notifyListeners();
    await _db?.setSetting(_wifiKey, on ? '1' : '0');
  }

  /// The once-a-day check, when the app opens or comes back.
  Future<void> maybeCheck() async {
    if (!Device.selfUpdate || !autoCheck || busy || hasUpdate) return;
    final last = checkedAt;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) return;
    await check();
  }

  /// Asks GitHub for the latest release. [manual] checks show "checking"
  /// and "up to date", and also show a version that was skipped.
  Future<void> check({bool manual = false}) async {
    if (busy) return;
    if (manual) _set(UpdateStage.checking, error: null);
    try {
      final r = await fetchLatest();
      checkedAt = DateTime.now();
      unawaited(_db?.setSetting(_lastKey, checkedAt!.toIso8601String()));
      final asset = Device.desktop ? r.desktopAsset : r.apkFor(abis);
      final newer = r.version > current && asset != null;
      if (newer && release?.tag != r.tag) {
        // A different version than one half downloaded: start again.
        received = 0;
        _file = null;
      }
      release = r;
      apk = asset;
      if (!newer) {
        _set(manual ? UpdateStage.upToDate : UpdateStage.idle);
        return;
      }
      if (!manual && r.tag == _skipped) {
        _set(UpdateStage.idle);
        return;
      }
      _set(UpdateStage.available);
      if (!manual) await _announce(r);
    } catch (e) {
      debugPrint('Update check failed: $e');
      if (manual) {
        _set(UpdateStage.failed, error: "Couldn't reach GitHub. Check that you're online and try again.");
      } else if (stage == UpdateStage.checking) {
        _set(UpdateStage.idle);
      }
    }
  }

  /// The latest release from the GitHub API. On a computer: the newest one
  /// with a download for it (Windows installer, zipped Mac app),
  /// pre-releases included.
  Future<Release> fetchLatest() async {
    final client = _newClient();
    try {
      final req = await client.getUrl(Uri.parse(Device.desktop ? _recent : _latest));
      req.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('GitHub answered ${res.statusCode}');
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (!Device.desktop) return Release.fromGitHub((jsonDecode(body) as Map).cast<String, Object?>());
      Release? best;
      for (final j in (jsonDecode(body) as List).cast<Map>()) {
        if (j['draft'] == true) continue;
        final r = Release.fromGitHub(j.cast<String, Object?>());
        if (r.desktopAsset == null) continue;
        if (best == null || r.version > best.version) best = r;
      }
      if (best == null) throw HttpException('No ${Device.macos ? 'Mac' : 'Windows'} release found');
      return best;
    } finally {
      client.close(force: true);
    }
  }

  /// The banner in the app, once per version, or a notification when the
  /// app isn't on screen.
  Future<void> _announce(Release r) async {
    final db = _db;
    if (db != null && await db.setting(_announcedKey) == r.tag) return;
    await db?.setSetting(_announcedKey, r.tag);
    if (_inForeground) {
      announcements.add(r);
    } else {
      await Notify.show(
        id: _notifyId,
        kind: 'update',
        title: 'ShareBro ${r.version} is here',
        text: r.notes.isEmpty ? 'Tap to see what\'s new and update' : r.notes.first.title.isNotEmpty ? r.notes.first.title : r.notes.first.text,
        open: 'update',
      );
    }
  }

  static bool get _inForeground {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  /// Don't offer this version again (a manual check still shows it).
  Future<void> skip() async {
    final r = release;
    if (r == null) return;
    _skipped = r.tag;
    await _db?.setSetting(_skipKey, r.tag);
    _set(UpdateStage.idle);
  }

  /// On mobile data with "Wi-Fi only" on: the UI asks first.
  Future<bool> shouldAskAboutData() async => wifiOnly && !await onUnmeteredNetwork();

  static Future<bool> onUnmeteredNetwork() async {
    try {
      return await _channel.invokeMethod<bool>('unmetered') ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  /// Downloads the APK, then checks it. Picks up a part already on the phone.
  Future<void> download() async {
    final r = release, a = apk;
    if (r == null || a == null || stage == UpdateStage.downloading || stage == UpdateStage.verifying) return;
    if (stage == UpdateStage.ready && _file != null && await _file!.exists()) return;
    _cancelled = false;
    badFile = false;
    speed = null;
    _set(UpdateStage.downloading, error: null);
    final dir = await _downloadsDir();
    final part = File('${dir.path}/${a.name}.part');
    final done = File('${dir.path}/${a.name}');
    final client = _client = _newClient();
    IOSink? sink;
    try {
      if (await done.exists() && await done.length() == a.size) {
        received = a.size;
      } else {
        var start = await part.exists() ? await part.length() : 0;
        if (start > a.size) {
          await part.delete();
          start = 0;
        }
        final req = await client.getUrl(Uri.parse(a.url));
        if (start > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable && start == a.size) {
          await res.drain<void>();
        } else {
          if (res.statusCode != HttpStatus.partialContent) start = 0;
          if (res.statusCode != HttpStatus.ok && res.statusCode != HttpStatus.partialContent) {
            throw HttpException('Download answered ${res.statusCode}');
          }
          received = start;
          sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
          var lastTick = DateTime.now(), lastBytes = received;
          var lastNote = DateTime(0);
          await for (final chunk in res.timeout(const Duration(seconds: 30))) {
            if (_cancelled) break;
            sink.add(chunk);
            received += chunk.length;
            final now = DateTime.now();
            final ms = now.difference(lastTick).inMilliseconds;
            if (ms >= 250) {
              final s = (received - lastBytes) * 1000 / ms;
              speed = speed == null ? s : speed! * 0.7 + s * 0.3;
              lastTick = now;
              lastBytes = received;
              notifyListeners();
            }
            if (now.difference(lastNote).inMilliseconds >= 1000) {
              lastNote = now;
              unawaited(_progressNotice(r, a));
            }
          }
          await sink.flush();
          await sink.close();
          sink = null;
        }
        if (_cancelled) {
          if (await part.exists()) await part.delete();
          received = 0;
          unawaited(Notify.cancel(_notifyId));
          _set(UpdateStage.available);
          return;
        }
        if (await part.length() != a.size) throw const HttpException('The download stopped early');
        if (await done.exists()) await done.delete();
        await part.rename(done.path);
      }
      _file = done;
      await _verify(r, a, done);
    } catch (e) {
      debugPrint('Update download failed: $e');
      await sink?.close().catchError((_) {});
      if (_cancelled) {
        received = 0;
        _set(UpdateStage.available);
      } else {
        _set(UpdateStage.failed,
            error: 'The connection dropped at ${formatBytes(received)}. Retry picks up where it stopped.');
        if (!_inForeground) {
          unawaited(Notify.show(
            id: _notifyId,
            kind: 'update',
            title: 'Update download paused',
            text: 'Tap to pick up where it stopped',
            open: 'update',
          ));
        } else {
          unawaited(Notify.cancel(_notifyId));
        }
      }
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  /// Stops the download and deletes what's there.
  void cancel() {
    if (stage != UpdateStage.downloading) return;
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<void> _progressNotice(Release r, ReleaseAsset a) => Notify.show(
        id: _notifyId,
        kind: 'progress',
        title: 'Downloading ShareBro ${r.version}',
        text: '${formatBytes(received)} of ${formatBytes(a.size)}'
            '${remaining == null ? '' : ' · ${_short(remaining!)} left'}',
        progress: progress,
        chip: '${(progress * 100).round()}%',
        open: 'update',
        actions: const [('cancel_update', 'Cancel')],
      );

  /// Size first, then SHA-256 against the release's checksum list.
  Future<void> _verify(Release r, ReleaseAsset a, File file) async {
    _set(UpdateStage.verifying);
    final shown = Future<void>.delayed(const Duration(milliseconds: 900));
    try {
      if (await file.length() != a.size) {
        await file.delete();
        throw const _Mismatch();
      }
      String? expected;
      final sums = r.checksums;
      if (sums != null) {
        final client = _newClient();
        try {
          final req = await client.getUrl(Uri.parse(sums.url));
          final res = await req.close().timeout(const Duration(seconds: 20));
          if (res.statusCode == 200) {
            expected = parseSums(await res.transform(utf8.decoder).join())[a.name];
          } else {
            await res.drain<void>();
          }
        } finally {
          client.close(force: true);
        }
      }
      if (expected != null) {
        final path = file.path;
        final actual = await Isolate.run(() async => (await sha256.bind(File(path).openRead()).first).toString());
        if (actual != expected) {
          await file.delete();
          throw const _Mismatch();
        }
      }
      checksumVerified = expected != null;
      await shown;
      _set(UpdateStage.ready);
      if (_inForeground) {
        unawaited(Notify.cancel(_notifyId));
      } else {
        unawaited(Notify.show(
          id: _notifyId,
          kind: 'update',
          title: 'ShareBro ${r.version} is ready to install',
          text: 'Downloaded and checked. Tap to install',
          open: 'update',
        ));
      }
    } on _Mismatch {
      received = 0;
      badFile = true;
      _file = null;
      await shown;
      unawaited(Notify.cancel(_notifyId));
      _set(UpdateStage.failed,
          error: "The download didn't match the file published on GitHub, so it was deleted. Try again.");
    }
  }

  /// Can ShareBro open Android's installer? (Settings › Install unknown apps.)
  /// Always on a computer.
  static Future<bool> canInstall() async {
    if (Device.desktop) return true;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the "Install unknown apps" switch for ShareBro.
  static Future<void> allowInstall() async {
    try {
      await _channel.invokeMethod('allowInstall');
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // No such screen on this phone.
    }
  }

  /// Hands the checked APK to Android's installer.
  Future<InstallResult> install() async {
    final file = _file, r = release;
    if (stage != UpdateStage.ready || file == null || r == null) return InstallResult.failed;
    if (!await file.exists()) {
      _file = null;
      received = 0;
      _set(UpdateStage.available);
      return InstallResult.failed;
    }
    if (!await canInstall()) return InstallResult.needsPermission;
    await _db?.setSetting(_installingKey, r.version.toString());
    if (Device.windows) return _installOnWindows(file);
    if (Device.macos) return _installOnMac(file);
    try {
      final ok = await _channel.invokeMethod<bool>('install', {'path': file.path}) ?? false;
      return ok ? InstallResult.started : InstallResult.failed;
    } on PlatformException catch (e) {
      debugPrint('Install failed: ${e.message}');
      return InstallResult.failed;
    } on MissingPluginException {
      return InstallResult.failed;
    }
  }

  /// Runs the downloaded installer quietly and closes ShareBro so its files
  /// can be replaced. The installer keeps the install it finds (for you or
  /// for everyone, asking Windows for permission if needed) and opens
  /// ShareBro again when it's done.
  Future<InstallResult> _installOnWindows(File file) async {
    try {
      await Process.start(
        file.path,
        const ['/SILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NOCANCEL', '/CLOSEAPPLICATIONS', '/NORESTART'],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('Install failed: $e');
      await _db?.setSetting(_installingKey, '');
      return InstallResult.failed;
    }
    // A moment for the installer to start, then get out of its way.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 800), () async {
      try {
        await _db?.close();
      } catch (_) {
        // Closing anyway.
      }
      exit(0);
    }));
    return InstallResult.started;
  }

  /// Mac: unzips the downloaded app next to the old one, then a small
  /// script waits for ShareBro to close, swaps the new app in and opens it.
  /// If the swap fails, the old app is put back.
  Future<InstallResult> _installOnMac(File zip) async {
    try {
      // .../ShareBro.app/Contents/MacOS/ShareBro
      final app = File(Platform.resolvedExecutable).parent.parent.parent.path;
      if (!app.endsWith('.app')) throw StateError('Not running from an app bundle: $app');
      final work = Directory('${(await getTemporaryDirectory()).path}/updates/unpacked');
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);
      final unzip = await Process.run('/usr/bin/ditto', ['-x', '-k', zip.path, work.path]);
      if (unzip.exitCode != 0) throw StateError('Unzip failed: ${unzip.stderr}');
      final fresh = work
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.endsWith('.app'))
          .firstOrNull;
      if (fresh == null) throw StateError('No app in the download');
      // Where the old app lives must be writable (it is for apps you
      // dragged into Applications yourself).
      final parent = Directory(app).parent.path;
      final probe = File('$parent/.sharebro_update_probe');
      await probe.writeAsString('');
      await probe.delete();
      final script = File('${work.path}/swap.sh');
      await script.writeAsString('''
#!/bin/sh
# Wait for ShareBro ($pid) to close, swap in the new app, open it.
while kill -0 "\$SB_PID" 2>/dev/null; do sleep 0.3; done
OLD="\$SB_OLD"; NEW="\$SB_NEW"
/usr/bin/xattr -dr com.apple.quarantine "\$NEW" 2>/dev/null
BACKUP="\$OLD.old-\$\$"
/bin/mv "\$OLD" "\$BACKUP" || exit 1
if /bin/mv "\$NEW" "\$OLD"; then
  /bin/rm -rf "\$BACKUP"
else
  /bin/mv "\$BACKUP" "\$OLD"
fi
/usr/bin/open "\$OLD"
''');
      await Process.start(
        '/bin/sh',
        [script.path],
        environment: {'SB_PID': '$pid', 'SB_OLD': app, 'SB_NEW': fresh.path},
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      debugPrint('Install failed: $e');
      await _db?.setSetting(_installingKey, '');
      return InstallResult.failed;
    }
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () async {
      try {
        await _db?.close();
      } catch (_) {
        // Closing anyway.
      }
      exit(0);
    }));
    return InstallResult.started;
  }

  /// After a failed check or download.
  Future<void> retry() => release == null || apk == null ? check(manual: true) : download();

  Future<Directory> _downloadsDir() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _clearDownloads() async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Android clears the cache anyway.
    }
  }

  HttpClient _newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'ShareBro-updater';

  void _set(UpdateStage s, {Object? error = _keep}) {
    stage = s;
    if (!identical(error, _keep)) this.error = error as String?;
    notifyListeners();
  }

  static String _short(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';
}

const _keep = Object();

class _Mismatch implements Exception {
  const _Mismatch();
}
