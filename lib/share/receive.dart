import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/db.dart';
import '../scan/background.dart';
import 'native_files.dart';

/// Gallery album received photos are saved into.
const receivedAlbum = 'ShareBro';

/// How long a request waits for you to tap Accept.
const _askTimeout = Duration(seconds: 90);

const _onKey = 'receive_on';
const _autoKey = 'receive_auto_paired';
const _pinKey = 'receive_pin';
const _quickKey = 'receive_quick';

/// A text message someone sent (LocalSend's "Text" option).
class IncomingMessage {
  IncomingMessage(this.from, this.text);

  final String from;
  final String text;
  final DateTime at = DateTime.now();
}

/// Someone wants to send you files; waiting for Accept / Decline.
class IncomingRequest {
  IncomingRequest(this.from, this.files, this.via);

  final String from;
  final List<IncomingFile> files;

  /// "Wi-Fi" (LocalSend) or "Nearby" (no network).
  final String via;
  final _answer = Completer<bool>();

  int get totalBytes => files.fold(0, (n, f) => n + f.size);
  bool get allMedia => files.every((f) => f.isMedia);

  /// "12 photos", "3 files", "a message".
  String get summary {
    if (files.every((f) => f.isMessage)) return files.length == 1 ? 'a message' : '${files.length} messages';
    final n = files.length;
    return allMedia ? '$n ${n == 1 ? 'photo' : 'photos'}' : '$n ${n == 1 ? 'file' : 'files'}';
  }
  bool get answered => _answer.isCompleted;
  void answer(bool yes) {
    if (!_answer.isCompleted) _answer.complete(yes);
  }
}

class IncomingFile {
  IncomingFile(this.id, this.fileName, this.size, this.mime, {this.sha256, this.preview});

  final String id;
  final String fileName;
  final int size;
  final String mime;
  final String? sha256;

  /// The text itself when this is a message rather than a file.
  final String? preview;

  bool get isMedia => mime.startsWith('image/') || mime.startsWith('video/');
  bool get isMessage => mime.startsWith('text/') && preview != null;
}

/// A transfer in progress (or just finished).
class ReceiveSession {
  ReceiveSession(this.id, this.from, this.files, this.tokens, this.ip);

  final String id;
  final String from;
  final Map<String, IncomingFile> files;
  final Map<String, String> tokens;
  final String? ip;
  final Set<String> done = {};
  final List<String> savedIds = [];

  /// Other files, saved to Downloads.
  int savedFiles = 0;
  int bytes = 0;
  bool finished = false;
  bool cancelled = false;
  final DateTime started = DateTime.now();

  int get totalBytes => tokens.keys.fold(0, (n, id) => n + (files[id]?.size ?? 0));
}

/// Receiving from friends, over LocalSend (Wi-Fi/hotspot) or Nearby (no
/// network). Photos and videos go into the gallery (and to [onSaved], which
/// scans them); other files into Download/ShareBro; messages are shown.
class Receiver extends ChangeNotifier {
  Receiver(this.db);

  final AppDb db;
  bool enabled = false;
  bool autoAcceptPaired = true;

  /// Accept everything without asking (LocalSend's "Quick Save").
  bool quickSave = false;
  String? pin;

  /// The latest message, until it's been shown.
  final message = ValueNotifier<IncomingMessage?>(null);

  IncomingRequest? pending;
  ReceiveSession? session;
  final List<ReceiveSession> history = [];

  /// Called with the gallery ids of newly saved photos.
  void Function(List<String> assetIds)? onSaved;

  Future<void> load() async {
    enabled = (await db.setting(_onKey)) == '1';
    autoAcceptPaired = (await db.setting(_autoKey)) != '0';
    quickSave = (await db.setting(_quickKey)) == '1';
    final p = await db.setting(_pinKey);
    pin = p == null || p.isEmpty ? null : p;
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await db.setSetting(_onKey, v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setAutoAccept(bool v) async {
    autoAcceptPaired = v;
    await db.setSetting(_autoKey, v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setQuickSave(bool v) async {
    quickSave = v;
    await db.setSetting(_quickKey, v ? '1' : '0');
    notifyListeners();
  }

  Future<void> setPin(String? v) async {
    pin = v == null || v.trim().isEmpty ? null : v.trim();
    await db.setSetting(_pinKey, pin ?? '');
    notifyListeners();
  }

  /// Asks (or auto-accepts) and returns which file ids are wanted, or null
  /// if declined. Messages are shown right away and need no transfer, so
  /// they return an empty set.
  Future<Set<String>?> ask(IncomingRequest req, {String? fingerprint}) async {
    if (req.files.isNotEmpty && req.files.every((f) => f.isMessage)) {
      for (final f in req.files) {
        await db.addTransfer(Transfer(
            incoming: true, peer: req.from, fileName: f.fileName, size: f.size, mime: f.mime, text: f.preview));
        message.value = IncomingMessage(req.from, f.preview!);
      }
      return {};
    }
    final all = {for (final f in req.files) f.id};
    if (all.isEmpty) return null;
    if (quickSave) return all;
    if (autoAcceptPaired && fingerprint != null) {
      final paired = await db.savedDevices();
      if (paired.any((d) =>
          d.fingerprint.toUpperCase() == fingerprint.toUpperCase() && (d.personId != null || d.favorite))) {
        return all;
      }
    }
    pending = req;
    notifyListeners();
    // Keep running while waiting, so a backgrounded app can still answer.
    await KeepAlive.hold('receive-ask', 'Files waiting', '${req.from} wants to send ${req.summary}');
    try {
      final yes = await req._answer.future.timeout(_askTimeout, onTimeout: () => false);
      return yes ? all : null;
    } finally {
      if (pending == req) pending = null;
      await KeepAlive.release('receive-ask');
      notifyListeners();
    }
  }

  ReceiveSession start(String from, Map<String, IncomingFile> files, Set<String> accepted, String? ip) {
    final r = math.Random.secure();
    String token() => List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
    final s = ReceiveSession(
      List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join(),
      from,
      files,
      {for (final id in accepted) id: token()},
      ip,
    );
    session = s;
    history.insert(0, s);
    if (history.length > 20) history.removeLast();
    KeepAlive.hold('receive', 'Receiving', 'From $from');
    notifyListeners();
    return s;
  }

  bool get busy => session != null && !session!.finished;

  /// Repaint progress (for transports that report it separately).
  void ping() => notifyListeners();

  /// Streams one file to disk, checks it, and saves it to the gallery.
  /// Returns an HTTP-style status code.
  Future<int> receive(ReceiveSession s, String fileId, Stream<List<int>> data) async {
    final f = s.files[fileId];
    if (f == null || s.finished) return 409;
    final dir = await getTemporaryDirectory();
    final tmp = File(p.join(dir.path, 'in_${s.id}_$fileId${p.extension(f.fileName)}'));
    final sink = tmp.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    try {
      var last = DateTime.now();
      await for (final chunk in data) {
        if (s.cancelled) {
          await sink.close();
          return 409;
        }
        sink.add(chunk);
        hasher.add(chunk);
        s.bytes += chunk.length;
        final now = DateTime.now();
        if (now.difference(last) > const Duration(milliseconds: 200)) {
          last = now;
          notifyListeners();
        }
      }
      await sink.close();
      hasher.close();
      if (f.sha256 != null && f.sha256!.toLowerCase() != digest.value.toString()) {
        return 422;
      }
      // Senders may put folders in the name ("Trip/day1/a.jpg").
      final parts = f.fileName.replaceAll('\\', '/').split('/').where((x) => x.isNotEmpty && x != '..').toList();
      final name = parts.isEmpty ? 'file' : parts.last;
      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : null;
      final String location;
      if (f.mime.startsWith('video/')) {
        final saved = await PhotoManager.editor.saveVideo(tmp, title: name, relativePath: 'Movies/$receivedAlbum');
        s.savedIds.add(saved.id);
        location = saved.id;
      } else if (f.mime.startsWith('image/')) {
        final saved = await PhotoManager.editor.saveImageWithPath(tmp.path,
            title: name, relativePath: 'Pictures/$receivedAlbum');
        s.savedIds.add(saved.id);
        location = saved.id;
      } else {
        location = await NativeFiles.saveToDownloads(tmp.path, name, f.mime, dir: folder) ?? '';
        s.savedFiles++;
      }
      await db.addTransfer(Transfer(
          incoming: true, peer: s.from, fileName: f.fileName, size: f.size, mime: f.mime, location: location));
      s.done.add(fileId);
      if (s.done.length == s.tokens.length) finish(s);
      notifyListeners();
      return 200;
    } catch (e) {
      debugPrint('Receive failed: $e');
      return 500;
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  void finish(ReceiveSession s, {bool cancelled = false}) {
    if (s.finished) return;
    s
      ..finished = true
      ..cancelled = cancelled;
    KeepAlive.release('receive');
    if (s.savedIds.isNotEmpty) onSaved?.call(List.of(s.savedIds));
    notifyListeners();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
