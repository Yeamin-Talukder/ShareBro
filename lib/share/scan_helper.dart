import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import '../data/db.dart' show NewFace;
import 'client.dart';
import 'net.dart';
import 'protocol.dart';

/// Scanning with your computer's help: a phone sends the small copies it
/// already makes for scanning (1600 px JPEGs) to one of your computers,
/// which finds the faces and fingerprints them on its graphics chip and
/// sends back only the results. The phone keeps scanning photos itself at
/// the same time, and carries on alone if the computer goes away.
///
/// Both run the same fingerprint model ([faceModel] must match), so faces
/// found by either belong to the same people. Copies are held only in
/// memory on the computer and never saved there. The face results can be
/// remembered there for a while (so the same photo is answered instantly
/// next time), only if the phone allows it and for as long as it says
/// ([ScanHelpProgress.keepDays]); the phone turning that off deletes them.
///
/// Pairing: the first time, the computer asks (Allow / Don't allow) and
/// both show the same 4-digit code; once allowed, the phone gets a pairing
/// key and is let in without asking from then on. Each session has its own
/// token, which every photo must carry.
const scanApi = '/api/sharebro/v1/scan';

/// How long a first request waits for someone to tap Allow.
const _answerWithin = Duration(minutes: 2);

/// Copies bigger than this are refused (a 1600 px JPEG is far smaller).
const _maxPhotoBytes = 12 << 20;

/// A phone asking to use this computer for the first time.
class ScanHelpRequest {
  ScanHelpRequest({required this.alias, required this.fingerprint, required this.code});

  final String alias, fingerprint;

  /// The 4-digit code the phone is showing; the two must match.
  final String code;

  final Completer<bool> _answer = Completer();
  bool get answered => _answer.isCompleted;

  void answer(bool yes) {
    if (!_answer.isCompleted) _answer.complete(yes);
  }
}

/// How long a phone may let its computer remember face results, in days
/// (0 is off). The phone's Settings choose; the computer only follows.
const scanHelpKeepChoices = [0, 1, 7, 30];

/// What a phone tells its computer with each photo: how its whole scan is
/// going, and how long the computer may remember results.
class ScanHelpProgress {
  const ScanHelpProgress({
    required this.done,
    required this.total,
    required this.rate,
    required this.keepDays,
    this.album,
  });

  /// Photos the phone has finished (by itself and with the computer).
  final int done, total;

  /// The phone's whole scan, photos a second.
  final double rate;
  final int keepDays;
  final String? album;
}

/// A phone this computer is scanning for right now.
class ScanHelpSession {
  ScanHelpSession(this.token, this.alias, this.fingerprint, {this.keepDays = 0});

  final String token, alias, fingerprint;
  final DateTime started = DateTime.now();

  /// Photos answered here (found now or remembered), faces in them,
  /// photos that failed, and photos answered from remembered results.
  int photos = 0, faces = 0, failed = 0, remembered = 0;

  /// Photo copies received, in bytes.
  int bytes = 0;

  /// Time spent finding faces here (remembered photos take none).
  int computeMs = 0;
  DateTime lastSeen = DateTime.now();

  /// How long this computer may remember the phone's results (the phone's
  /// setting); 0 is off.
  int keepDays;

  /// Results remembered for this phone now: how many, and their size.
  int keptCount = 0, keptBytes = 0;

  /// The phone's whole scan, as it last said.
  int? phoneDone, phoneTotal;
  double? phoneRate;
  String? album;

  final List<DateTime> _recent = [];

  /// Busy in the last half minute.
  bool get active => DateTime.now().difference(lastSeen) < const Duration(seconds: 30);

  void _answered() {
    final now = DateTime.now();
    _recent.add(now);
    _recent.removeWhere((t) => now.difference(t) > _rateWindow);
  }

  /// Photos a second answered here, over the last few seconds.
  double get rate {
    final now = DateTime.now();
    _recent.removeWhere((t) => now.difference(t) > _rateWindow);
    if (_recent.isEmpty) return 0;
    final span = now.difference(started) < _rateWindow ? now.difference(started) : _rateWindow;
    return _recent.length / math.max(1.0, span.inMilliseconds / 1000);
  }

  /// Photos the phone still has to scan.
  int? get remaining {
    final d = phoneDone, t = phoneTotal;
    return d == null || t == null ? null : math.max(0, t - d);
  }

  /// The phone's whole scan, at its current speed.
  Duration? get timeLeft {
    final left = remaining, r = phoneRate;
    if (left == null || r == null || r < 0.05) return null;
    return Duration(seconds: (left / r).round());
  }

  /// The part of the phone's photos answered here.
  double? get share {
    final d = phoneDone;
    return d == null || d == 0 ? null : math.min(1.0, photos / d);
  }

  /// Milliseconds a photo, for photos actually scanned here.
  int? get msPerPhoto {
    final n = photos - remembered;
    return n <= 0 ? null : computeMs ~/ n;
  }
}

/// Rates are counted over this long.
const _rateWindow = Duration(seconds: 10);

// ---- Faces on the wire ----

Map<String, Object?> faceToJson(NewFace f) => {
      'l': f.left,
      't': f.top,
      'w': f.width,
      'h': f.height,
      'e': base64Encode(f.embedding.buffer.asUint8List(f.embedding.offsetInBytes, f.embedding.lengthInBytes)),
      'th': base64Encode(f.thumb),
      's': f.sharpness,
      if (f.eyesOpen != null) 'eo': f.eyesOpen,
      if (f.smile != null) 'sm': f.smile,
      if (f.yaw != null) 'y': f.yaw,
    };

/// Null if malformed, or if the fingerprint isn't [dim] numbers long.
NewFace? faceFromJson(Object? j, {int dim = 512}) {
  if (j is! Map) return null;
  double? n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  final l = n(j['l']), t = n(j['t']), w = n(j['w']), h = n(j['h']), s = n(j['s']);
  final e = j['e'], th = j['th'];
  if (l == null || t == null || w == null || h == null || s == null || e is! String || th is! String) return null;
  try {
    final bytes = base64Decode(e);
    if (bytes.length != dim * 4) return null;
    final embedding = Float32List.view(Uint8List.fromList(bytes).buffer);
    if (embedding.any((x) => x.isNaN || x.isInfinite)) return null;
    final thumb = base64Decode(th);
    if (thumb.length > 200000) return null;
    return NewFace(
      left: l.clamp(0.0, 1.0),
      top: t.clamp(0.0, 1.0),
      width: w.clamp(0.0, 1.0),
      height: h.clamp(0.0, 1.0),
      embedding: embedding,
      thumb: thumb,
      sharpness: s,
      eyesOpen: n(j['eo']),
      smile: n(j['sm']),
      yaw: n(j['y']),
    );
  } catch (_) {
    return null;
  }
}

String _random(int bytes) {
  final r = math.Random.secure();
  return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
}

// ---- The computer's side ----

/// Answers phones that want this computer to scan for them (desktop).
class ScanHelperHub extends ChangeNotifier {
  ScanHelperHub({
    required this.readSetting,
    required this.writeSetting,
    required this.faceModel,
    required this.analyze,
    required this.alias,
    this.resultsRoot,
  });

  /// Where remembered face results go (a folder per phone); without it
  /// nothing is remembered.
  final Future<Directory> Function()? resultsRoot;

  /// Where the on/off switch and the allowed phones are kept (the app's
  /// settings table).
  final Future<String?> Function(String key) readSetting;
  final Future<void> Function(String key, String value) writeSetting;
  final String faceModel;

  /// This computer's name, sent back to the phone.
  final String Function() alias;

  /// Faces in one upright JPEG (the phone's scan copy).
  final Future<List<NewFace>> Function(Uint8List jpeg) analyze;

  static const _allowKey = 'scan_helper_allow';
  static const _pairedKey = 'scan_helper_paired';

  /// Letting phones ask at all (Settings › General).
  bool allowed = true;

  /// Phones allowed before: fingerprint → (name, pairing key, days their
  /// results may be remembered).
  Map<String, ({String alias, String key, int keep})> _paired = {};
  int get pairedCount => _paired.length;

  /// A first request waiting for Allow / Don't allow.
  ScanHelpRequest? pending;

  /// Sessions by token.
  final Map<String, ScanHelpSession> sessions = {};

  /// Phones being scanned for right now.
  List<ScanHelpSession> get active => [for (final s in sessions.values) if (s.active) s];

  Timer? _idle;

  Future<void> load() async {
    allowed = await readSetting(_allowKey) != '0';
    final saved = await readSetting(_pairedKey);
    _paired = {};
    if (saved != null && saved.isNotEmpty) {
      try {
        final m = (jsonDecode(saved) as Map).cast<String, dynamic>();
        for (final e in m.entries) {
          final v = (e.value as Map).cast<String, dynamic>();
          _paired[e.key] = (
            alias: v['alias'] as String? ?? 'Phone',
            key: v['key'] as String,
            keep: (v['keep'] as num?)?.toInt() ?? 0,
          );
        }
      } catch (_) {}
    }
    notifyListeners();
    // Results past their phone's period go now, and those of phones no
    // longer allowed.
    unawaited(_sweepAll());
  }

  Future<void> _savePaired() => writeSetting(
      _pairedKey,
      jsonEncode({
        for (final e in _paired.entries) e.key: {'alias': e.value.alias, 'key': e.value.key, 'keep': e.value.keep},
      }));

  // ---- Remembered results ----

  Future<Directory?> _phoneDir(String fingerprint) async {
    final root = await resultsRoot?.call();
    if (root == null) return null;
    final name = sha256.convert(utf8.encode(fingerprint)).toString().substring(0, 20);
    return Directory('${root.path}${Platform.pathSeparator}scan_helper_results${Platform.pathSeparator}$name');
  }

  String get _modelFolder => faceModel.replaceAll(RegExp(r'[^\w.-]'), '_');

  /// Follows the phone's setting: 0 deletes everything remembered for it;
  /// otherwise results older than [keep] days go. Counts what's left.
  Future<void> _applyKeep(ScanHelpSession? session, String fingerprint, int keep) async {
    final known = _paired[fingerprint];
    if (known != null && known.keep != keep) {
      _paired[fingerprint] = (alias: known.alias, key: known.key, keep: keep);
      await _savePaired();
    }
    final dir = await _phoneDir(fingerprint);
    var count = 0, size = 0;
    try {
      if (dir != null && await dir.exists()) {
        if (keep <= 0) {
          await dir.delete(recursive: true);
        } else {
          final cutoff = DateTime.now().subtract(Duration(days: keep));
          await for (final e in dir.list(recursive: true)) {
            if (e is! File) continue;
            final stat = await e.stat();
            // Another face model's results can't be used any more.
            if (stat.modified.isBefore(cutoff) || !e.parent.path.endsWith(_modelFolder)) {
              await e.delete();
            } else {
              count++;
              size += stat.size;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Scan helper: tidying remembered results failed: $e');
    }
    if (session != null) {
      session
        ..keepDays = keep
        ..keptCount = count
        ..keptBytes = size;
    }
  }

  Future<void> _sweepAll() async {
    final root = await resultsRoot?.call();
    if (root == null) return;
    final all = Directory('${root.path}${Platform.pathSeparator}scan_helper_results');
    if (!await all.exists()) return;
    final wanted = <String, String>{};
    for (final fp in _paired.keys) {
      final d = await _phoneDir(fp);
      if (d != null) wanted[d.path] = fp;
    }
    try {
      await for (final e in all.list()) {
        final fp = wanted[e.path];
        if (fp == null) {
          await e.delete(recursive: true);
        } else {
          await _applyKeep(null, fp, _paired[fp]!.keep);
        }
      }
    } catch (e) {
      debugPrint('Scan helper: tidying remembered results failed: $e');
    }
  }

  Future<File?> _resultFile(ScanHelpSession session, Uint8List jpeg) async {
    final dir = await _phoneDir(session.fingerprint);
    if (dir == null) return null;
    final hash = sha256.convert(jpeg).toString();
    return File('${dir.path}${Platform.pathSeparator}$_modelFolder${Platform.pathSeparator}$hash.json');
  }

  Future<List<NewFace>?> _remembered(ScanHelpSession session, Uint8List jpeg) async {
    if (session.keepDays <= 0) return null;
    try {
      final file = await _resultFile(session, jpeg);
      if (file == null || !await file.exists()) return null;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > Duration(days: session.keepDays)) {
        await file.delete();
        return null;
      }
      final list = (jsonDecode(await file.readAsString()) as Map)['faces'];
      if (list is! List) return null;
      final faces = <NewFace>[];
      for (final f in list) {
        final face = faceFromJson(f);
        if (face == null) return null;
        faces.add(face);
      }
      return faces;
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(ScanHelpSession session, Uint8List jpeg, List<NewFace> faces) async {
    if (session.keepDays <= 0) return;
    try {
      final file = await _resultFile(session, jpeg);
      if (file == null) return;
      await file.parent.create(recursive: true);
      final text = jsonEncode({'faces': [for (final f in faces) faceToJson(f)]});
      await file.writeAsString(text);
      session
        ..keptCount += 1
        ..keptBytes += text.length;
    } catch (e) {
      debugPrint('Scan helper: remembering a result failed: $e');
    }
  }

  /// Deletes what this computer remembers for [session]'s phone now (the
  /// phone's setting stays as it is).
  Future<void> forgetResults(ScanHelpSession session) async {
    final dir = await _phoneDir(session.fingerprint);
    try {
      if (dir != null && await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    session
      ..keptCount = 0
      ..keptBytes = 0;
    notifyListeners();
  }

  Future<void> setAllowed(bool on) async {
    allowed = on;
    if (!on) sessions.clear();
    notifyListeners();
    await writeSetting(_allowKey, on ? '1' : '0');
  }

  /// Forgets every phone, and every result remembered for them: each must
  /// be allowed again.
  Future<void> forgetAll() async {
    _paired.clear();
    sessions.clear();
    notifyListeners();
    await _savePaired();
    final root = await resultsRoot?.call();
    final all = root == null ? null : Directory('${root.path}${Platform.pathSeparator}scan_helper_results');
    try {
      if (all != null && await all.exists()) await all.delete(recursive: true);
    } catch (_) {}
  }

  /// Stops scanning for one phone now (it carries on by itself).
  void stop(ScanHelpSession s) {
    sessions.remove(s.token);
    notifyListeners();
  }

  /// Answers scan-helper requests; false for anything else.
  Future<bool> handle(HttpRequest req, String? ip) async {
    if (req.method != 'POST' || !req.uri.path.startsWith(scanApi)) return false;
    final res = req.response;
    switch (req.uri.path) {
      case '$scanApi/hello':
        return _hello(req, res);
      case '$scanApi/faces':
        return _faces(req, res);
      default:
        return _reply(res, HttpStatus.notFound);
    }
  }

  Future<bool> _hello(HttpRequest req, HttpResponse res) async {
    Map<String, dynamic> body;
    try {
      if (req.contentLength > 64 * 1024) return await _reply(res, HttpStatus.requestEntityTooLarge);
      body = (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, dynamic>();
    } catch (_) {
      return _reply(res, HttpStatus.badRequest);
    }
    if (!allowed) return _reply(res, HttpStatus.forbidden, {'reason': 'off'});
    final phoneAlias = (body['alias'] as String?)?.trim();
    final fp = body['fingerprint'];
    final key = body['key'];
    final code = body['code'];
    if (fp is! String || fp.isEmpty || fp.length > 128) return _reply(res, HttpStatus.badRequest);
    if (body['model'] != faceModel) return _reply(res, HttpStatus.conflict, {'reason': 'model', 'model': faceModel});
    final name = phoneAlias == null || phoneAlias.isEmpty
        ? 'A phone'
        : phoneAlias.substring(0, math.min(phoneAlias.length, 60));

    final known = _paired[fp];
    String? newKey;
    if (known == null || key != known.key) {
      // First time (or a key that doesn't match): ask here.
      if (code is! String || !RegExp(r'^\d{4}$').hasMatch(code)) return _reply(res, HttpStatus.unauthorized);
      if (pending != null) return _reply(res, HttpStatus.conflict, {'reason': 'busy'});
      final request = ScanHelpRequest(alias: name, fingerprint: fp, code: code);
      pending = request;
      notifyListeners();
      bool yes;
      try {
        yes = await request._answer.future.timeout(_answerWithin, onTimeout: () => false);
      } finally {
        pending = null;
        notifyListeners();
      }
      if (!yes) return _reply(res, HttpStatus.forbidden, {'reason': 'declined'});
      newKey = _random(24);
      _paired[fp] = (alias: name, key: newKey, keep: 0);
      await _savePaired();
    }
    final token = _random(24);
    // One session per phone.
    sessions.removeWhere((_, s) => s.fingerprint == fp);
    final session = ScanHelpSession(token, name, fp);
    final keep = body['keep'];
    await _applyKeep(session, fp, keep is int && scanHelpKeepChoices.contains(keep) ? keep : 0);
    sessions[token] = session;
    notifyListeners();
    return _reply(res, HttpStatus.ok, {
      'token': token,
      'key': ?newKey,
      'alias': alias(),
      'model': faceModel,
    });
  }

  Future<bool> _faces(HttpRequest req, HttpResponse res) async {
    final session = sessions[req.headers.value('x-scan-token') ?? ''];
    if (!allowed || session == null) return _reply(res, HttpStatus.unauthorized);
    if (req.contentLength > _maxPhotoBytes) return _reply(res, HttpStatus.requestEntityTooLarge);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > _maxPhotoBytes) return _reply(res, HttpStatus.requestEntityTooLarge);
    }
    final jpeg = builder.takeBytes();
    _readProgress(session, req.headers);
    final keep = int.tryParse(req.headers.value('x-scan-keep') ?? '');
    if (keep != null && scanHelpKeepChoices.contains(keep) && keep != session.keepDays) {
      await _applyKeep(session, session.fingerprint, keep);
    }
    session
      ..bytes += jpeg.length
      ..lastSeen = DateTime.now();
    var faces = await _remembered(session, jpeg);
    if (faces != null) {
      session.remembered++;
    } else {
      final watch = Stopwatch()..start();
      try {
        faces = await analyze(jpeg);
      } catch (e) {
        debugPrint('Scan helper: a photo failed: $e');
        session.failed++;
        return _reply(res, HttpStatus.unprocessableEntity);
      }
      session.computeMs += watch.elapsedMilliseconds;
      await _remember(session, jpeg, faces);
    }
    session
      ..photos += 1
      ..faces += faces.length
      .._answered();
    // Redraw "Sharing now" now and then, not for every photo.
    _idle ??= Timer(const Duration(seconds: 1), () {
      _idle = null;
      notifyListeners();
    });
    return _reply(res, HttpStatus.ok, {'faces': [for (final f in faces) faceToJson(f)]});
  }

  /// What the phone says about its whole scan (headers on each photo).
  void _readProgress(ScanHelpSession session, HttpHeaders h) {
    final done = int.tryParse(h.value('x-scan-done') ?? '');
    final total = int.tryParse(h.value('x-scan-total') ?? '');
    final rate = double.tryParse(h.value('x-scan-rate') ?? '');
    if (done != null && total != null && done >= 0 && total >= done) {
      session
        ..phoneDone = done
        ..phoneTotal = total;
    }
    if (rate != null && rate.isFinite && rate >= 0) session.phoneRate = rate;
    final album = h.value('x-scan-album');
    if (album != null) {
      try {
        final name = Uri.decodeComponent(album).trim();
        session.album = name.isEmpty ? null : name.substring(0, math.min(name.length, 80));
      } catch (_) {}
    }
  }

  Future<bool> _reply(HttpResponse res, int status, [Object? json]) async {
    res.statusCode = status;
    if (json != null) {
      res.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(json));
      res.contentLength = bytes.length;
      res.add(bytes);
    }
    await res.close();
    return true;
  }
}

// ---- The phone's side ----

/// Why the computer couldn't help.
enum ScanHelpRefusal { off, declined, busy, model, unreachable }

class ScanHelpException implements Exception {
  ScanHelpException(this.reason);

  final ScanHelpRefusal reason;

  String get message => switch (reason) {
        ScanHelpRefusal.off => 'Helping phones is turned off on the computer (Settings › General).',
        ScanHelpRefusal.declined => 'The computer didn\'t allow it.',
        ScanHelpRefusal.busy => 'The computer is answering another phone. Try again in a moment.',
        ScanHelpRefusal.model => 'The computer uses a different face model. Update ShareBro on both.',
        ScanHelpRefusal.unreachable => 'Couldn\'t reach the computer. Check both are on the same Wi‑Fi.',
      };

  @override
  String toString() => message;
}

/// A phone's connection to a computer that scans for it.
class ScanHelperClient {
  ScanHelperClient._(this._client, this._base, this.token, this.alias);

  final HttpClient _client;
  final Uri _base;
  final String token;

  /// The computer's name.
  final String alias;

  /// Photos sent and faces found so far.
  int photos = 0, faces = 0;
  bool _closed = false;

  /// The phone's scan as it is now, sent with each photo (see
  /// [ScanHelpProgress]).
  ScanHelpProgress Function()? progress;

  /// Starts a session with [device]. With a [key] from an earlier pairing
  /// it's let straight in; otherwise the computer asks (showing [code]),
  /// and [onKey] gets the new key once allowed.
  static Future<ScanHelperClient> connect(
    LsDevice device, {
    required ShareIdentity me,
    required String faceModel,
    String? key,
    String? code,
    void Function(String key)? onKey,
    Uri? base,
    int keepDays = 0,
  }) async {
    final client = lsHttpClient(fingerprint: device.fingerprint, identity: me.tls);
    final root = base ?? Uri(scheme: 'https', host: device.ip, port: device.info.port);
    try {
      final res = await postJson(
        client,
        root.replace(path: '$scanApi/hello'),
        {
          'alias': me.alias,
          'fingerprint': me.fingerprint,
          'model': faceModel,
          'key': ?key,
          'code': ?code,
          'keep': keepDays,
        },
        timeout: key == null ? _answerWithin + const Duration(seconds: 20) : const Duration(seconds: 8),
      );
      final reason = res.json?['reason'];
      if (res.status == HttpStatus.ok) {
        final token = res.json?['token'];
        if (token is! String) throw ScanHelpException(ScanHelpRefusal.unreachable);
        final newKey = res.json?['key'];
        if (newKey is String) onKey?.call(newKey);
        return ScanHelperClient._(client, root, token, (res.json?['alias'] as String?) ?? device.alias);
      }
      client.close(force: true);
      throw ScanHelpException(switch (reason) {
        'off' => ScanHelpRefusal.off,
        'model' => ScanHelpRefusal.model,
        'busy' => ScanHelpRefusal.busy,
        _ when res.status == HttpStatus.forbidden || res.status == HttpStatus.unauthorized => ScanHelpRefusal.declined,
        _ => ScanHelpRefusal.unreachable,
      });
    } on ScanHelpException {
      rethrow;
    } catch (e) {
      client.close(force: true);
      debugPrint('Scan helper: connecting failed: $e');
      throw ScanHelpException(ScanHelpRefusal.unreachable);
    }
  }

  /// The faces the computer found in [jpeg]. Throws if it couldn't (the
  /// caller then scans the photo itself).
  Future<List<NewFace>> scan(Uint8List jpeg) async {
    if (_closed) throw StateError('closed');
    final req = await _client.postUrl(_base.replace(path: '$scanApi/faces')).timeout(const Duration(seconds: 8));
    req.headers
      ..contentType = ContentType('image', 'jpeg')
      ..set('x-scan-token', token);
    final p = progress?.call();
    if (p != null) {
      req.headers
        ..set('x-scan-done', '${p.done}')
        ..set('x-scan-total', '${p.total}')
        ..set('x-scan-rate', p.rate.toStringAsFixed(2))
        ..set('x-scan-keep', '${p.keepDays}');
      final album = p.album;
      if (album != null) req.headers.set('x-scan-album', Uri.encodeComponent(album));
    }
    req.contentLength = jpeg.length;
    req.add(jpeg);
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
    if (res.statusCode != HttpStatus.ok) throw HttpException('Scan helper answered ${res.statusCode}');
    final list = (jsonDecode(text) as Map)['faces'];
    if (list is! List) throw const FormatException('No faces list');
    final found = <NewFace>[];
    for (final f in list) {
      final face = faceFromJson(f);
      if (face == null) throw const FormatException('Bad face');
      found.add(face);
    }
    photos++;
    faces += found.length;
    return found;
  }

  void close() {
    _closed = true;
    _client.close(force: true);
  }
}
