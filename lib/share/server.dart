import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:photo_manager/photo_manager.dart';

import '../scan/background.dart';
import '../ui/widgets.dart' show AssetThumb;
import 'discovery.dart';
import 'find_page.dart';
import 'group.dart';
import 'net.dart';
import 'prepare.dart';
import 'protocol.dart';
import 'receive.dart';
import 'web_page.dart';
import 'zip_stream.dart';

/// Port for the browser gallery (plain HTTP: browsers reject self-made
/// certificates, so LocalSend serves its browser mode over HTTP too).
const webPort = 53318;

/// A personal web gallery: one person's photos, reachable from a QR code.
/// It stays open (even in the background) until it's stopped.
class WebShare {
  WebShare({
    required this.id,
    required this.title,
    required this.files,
    required this.tmp,
    this.pin,
  });

  final String id;
  final String title;
  final List<PreparedFile> files;
  final Directory tmp;
  final DateTime created = DateTime.now();
  String? pin;
  int downloads = 0;
  final Set<String> visitors = {};

  /// ZIP downloads, split so each stays under the size limit.
  late final List<List<PreparedFile>> parts = zipParts(files, (f) => f.size);
}

/// A "Find my photos" link: a friend takes a selfie in the browser, this
/// phone works out who they are and opens a gallery of the photos they're
/// in. The selfie never leaves this phone and is deleted straight away.
class FindLink {
  FindLink({required this.id, required this.title, this.tripId, this.pin});

  final String id;
  final String title;

  /// Only photos from this trip, when set.
  final int? tripId;
  final DateTime created = DateTime.now();
  String? pin;

  /// Person id -> id of the gallery opened for them.
  final Map<int, String> galleries = {};

  /// Names of everyone found so far, first found first.
  final List<String> found = [];
  int tries = 0;
}

/// Matches a selfie to someone and opens their gallery; null when the face
/// isn't anyone we know.
typedef SelfieMatcher = Future<({WebShare share, String name})?> Function(FindLink link, File selfie);

/// Selfies are shrunk in the browser first; anything bigger is refused.
const _maxSelfieBytes = 8 << 20;

/// Our side of the LocalSend protocol over HTTPS (with our own
/// certificate): `/register` and `/info` so others find us, and
/// `prepare-upload` / `upload` / `cancel` to receive. Plus the browser
/// gallery on a separate plain-HTTP port.
class ShareServer extends ChangeNotifier {
  ShareServer(this.identity, this.discovery, this.receiver);

  final ShareIdentity identity;
  final Discovery discovery;
  final Receiver receiver;
  HttpServer? _secure;
  HttpServer? _web;
  final Map<String, WebShare> shares = {};
  final Map<String, FindLink> finds = {};

  /// Set by the app once faces can be matched.
  SelfieMatcher? onSelfie;

  /// Trip groups (ShareBro's own API on the HTTPS port).
  GroupHub? groups;

  int get webServerPort => _web?.port ?? webPort;
  bool get running => _secure != null;

  Future<void> start() async {
    if (_secure == null) {
      // If the LocalSend app itself runs on this phone it may hold 53317.
      for (var p = lsPort; p < lsPort + 10 && _secure == null; p++) {
        if (p == webPort) continue;
        try {
          _secure = await HttpServer.bindSecure(InternetAddress.anyIPv4, p, identity.tls.context(), shared: true);
          identity.port = p;
        } catch (_) {}
      }
      _secure?.listen(_handleApi, onError: (Object e) => debugPrint('Share server: $e'));
    }
    if (_web == null) {
      for (var p = webPort; p < webPort + 10 && _web == null; p++) {
        try {
          _web = await HttpServer.bind(InternetAddress.anyIPv4, p, shared: true);
        } catch (_) {}
      }
      _web?.listen(_handleWeb, onError: (Object e) => debugPrint('Web share: $e'));
    }
  }

  Future<void> stop() async {
    await _secure?.close(force: true);
    await _web?.close(force: true);
    _secure = null;
    _web = null;
  }

  /// Opens a web gallery for [files]; it stays reachable until [closeShare].
  WebShare openShare(String title, List<PreparedFile> files, Directory tmp, {String? pin}) {
    final id = _newId();
    final share = WebShare(id: id, title: title, files: files, tmp: tmp, pin: pin);
    shares[id] = share;
    KeepAlive.hold('web-$id', 'Sharing by link', '${share.title} · ${files.length} files');
    notifyListeners();
    return share;
  }

  Future<void> closeShare(String id) async {
    final s = shares.remove(id);
    await KeepAlive.release('web-$id');
    notifyListeners();
    if (s != null && await s.tmp.exists()) await s.tmp.delete(recursive: true);
  }

  Future<String?> linkFor(WebShare share) async {
    final ip = await localIp();
    return ip == null ? null : 'http://$ip:$webServerPort/?s=${share.id}';
  }

  /// Opens a "Find my photos" link; it stays reachable until [closeFind].
  FindLink openFind(String title, {int? tripId}) {
    final link = FindLink(id: _newId(), title: title, tripId: tripId);
    finds[link.id] = link;
    KeepAlive.hold('find-${link.id}', 'Find my photos link', title);
    notifyListeners();
    return link;
  }

  /// Closes the link and every gallery it opened.
  Future<void> closeFind(String id) async {
    final link = finds.remove(id);
    await KeepAlive.release('find-$id');
    notifyListeners();
    for (final g in link?.galleries.values ?? const <String>[]) {
      await closeShare(g);
    }
  }

  Future<String?> findLinkFor(FindLink link) async {
    final ip = await localIp();
    return ip == null ? null : 'http://$ip:$webServerPort/find?f=${link.id}';
  }

  static String _newId() {
    final r = math.Random.secure();
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    return List.generate(10, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // ---- LocalSend API (HTTPS) ----

  Future<void> _handleApi(HttpRequest req) async {
    final res = req.response;
    final ip = req.connectionInfo?.remoteAddress.address;
    try {
      final q = req.uri.queryParameters;
      switch ((req.method, req.uri.path)) {
        case ('POST', '$lsApi/register'):
          final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
          if (ip != null) discovery.add(LsInfo.fromJson(body), ip);
          return await _json(res, identity.info().toJson());
        case ('GET', '$lsApi/info'):
          return await _json(res, identity.info().toJson());
        case ('POST', '$lsApi/prepare-upload'):
          return await _prepareUpload(req, res, q, ip);
        case ('POST', '$lsApi/upload'):
          final s = receiver.session;
          final fileId = q['fileId'];
          if (s == null || s.finished || q['sessionId'] != s.id) return await _status(res, HttpStatus.conflict);
          if (fileId == null || s.tokens[fileId] != q['token'] || (s.ip != null && s.ip != ip)) {
            return await _status(res, HttpStatus.forbidden);
          }
          return await _status(res, await receiver.receive(s, fileId, req));
        case ('POST', '$lsApi/cancel'):
          final s = receiver.session;
          if (s != null && q['sessionId'] == s.id) receiver.finish(s, cancelled: true);
          return await _status(res, HttpStatus.ok);
        default:
          if (await groups?.handle(req, ip) ?? false) return;
          return await _status(res, HttpStatus.notFound);
      }
    } catch (e) {
      debugPrint('Share request failed: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _prepareUpload(HttpRequest req, HttpResponse res, Map<String, String> q, String? ip) async {
    if (receiver.busy || receiver.pending != null) return _status(res, HttpStatus.conflict);
    final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final info = LsInfo.fromJson((body['info'] as Map).cast<String, dynamic>());
    // Phones in your trip group skip the PIN and the question.
    final member = groups?.trusts(info.fingerprint) ?? false;
    if (!member && receiver.pin != null && q['pin'] != receiver.pin) return _status(res, HttpStatus.unauthorized);
    final files = <String, IncomingFile>{
      for (final e in (body['files'] as Map).entries)
        e.key as String: IncomingFile(
          e.key as String,
          (e.value as Map)['fileName'] as String? ?? 'photo',
          ((e.value as Map)['size'] as num?)?.toInt() ?? 0,
          (e.value as Map)['fileType'] as String? ?? mimeFor((e.value as Map)['fileName'] as String? ?? ''),
          sha256: (e.value as Map)['sha256'] as String?,
          preview: (e.value as Map)['preview'] as String?,
        ),
    };
    if (files.isEmpty) return _status(res, HttpStatus.noContent);
    final request = IncomingRequest(info.alias, files.values.toList(), 'Wi-Fi');
    // Like LocalSend: while the app is on screen we always ask, even with
    // Receive switched off. Closed or in the background with Receive off,
    // we say no, but tell both sides why.
    final onScreen = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!receiver.enabled && !onScreen && !member) {
      receiver.missed.value = request;
      res
        ..statusCode = HttpStatus.forbidden
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'message': 'Receiving is off'}));
      return res.close();
    }
    final accepted = member ? {for (final f in files.keys) f} : await receiver.ask(request, fingerprint: info.fingerprint);
    if (accepted == null) return _status(res, HttpStatus.forbidden);
    if (accepted.isEmpty) return _status(res, HttpStatus.noContent);
    final s = receiver.start(info.alias, files, accepted, ip);
    return _json(res, {'sessionId': s.id, 'files': s.tokens});
  }

  // ---- Browser gallery (HTTP) ----

  Future<void> _handleWeb(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    try {
      final q = req.uri.queryParameters;
      switch ((req.method, req.uri.path)) {
        case ('POST', '$lsApi/prepare-download') || ('GET', '$lsApi/prepare-download'):
          final share = _authorised(req, res);
          if (share == null) return;
          final ip = req.connectionInfo?.remoteAddress.address;
          if (ip != null && share.visitors.add(ip)) notifyListeners();
          return await _json(res, {
            'info': identity.info(download: true).toJson(),
            'sessionId': share.id,
            'title': share.title,
            'files': {
              for (var i = 0; i < share.files.length; i++)
                'p$i': {
                  ...LsFile(
                    id: 'p$i',
                    fileName: share.files[i].fileName,
                    size: share.files[i].size,
                    fileType: share.files[i].mime,
                  ).toJson(),
                  // For grouping by day in the gallery page.
                  'taken': share.files[i].modified?.toIso8601String(),
                },
            },
            'zipLimit': zipPartLimit,
            'zipParts': [
              for (final part in share.parts) {'size': zipLength(_entries(part))},
            ],
          });
        case ('GET', '$lsApi/download'):
          final share = _authorised(req, res);
          if (share == null) return;
          final f = _file(share, q['fileId']);
          if (f == null) return await _status(res, HttpStatus.notFound);
          share.downloads++;
          notifyListeners();
          res.headers
            ..contentType = ContentType.parse(f.mime)
            ..contentLength = f.size
            ..set('Content-Disposition', _attachment(f.fileName));
          await res.addStream(f.open());
          return await res.close();
        case ('GET', '/thumb'):
          final share = _authorised(req, res);
          if (share == null) return;
          final f = _file(share, q['fileId']);
          if (f != null && !f.isAsset) return await _fileTile(res, f);
          final asset = f == null ? null : await AssetThumb.entity(f.assetId);
          final bytes = await asset?.thumbnailDataWithSize(const ThumbnailSize.square(360), quality: 80);
          if (bytes == null) return await _status(res, HttpStatus.notFound);
          res.headers
            ..contentType = ContentType('image', 'jpeg')
            ..set('Cache-Control', 'max-age=3600');
          res.add(bytes);
          return await res.close();
        case ('GET', '/preview'):
          // A screen-sized copy for the full-screen viewer: quick to load,
          // the original is still one tap away.
          final share = _authorised(req, res);
          if (share == null) return;
          final f = _file(share, q['fileId']);
          if (f != null && !f.isAsset) return await _fileTile(res, f);
          final asset = f == null ? null : await AssetThumb.entity(f.assetId);
          if (asset == null) return await _status(res, HttpStatus.notFound);
          final w = asset.orientatedWidth, h = asset.orientatedHeight;
          final scale = w <= 0 || h <= 0 ? 1.0 : math.min(1.0, 1800 / math.max(w, h));
          final bytes = await asset.thumbnailDataWithSize(
              w <= 0 || h <= 0
                  ? const ThumbnailSize.square(1800)
                  : ThumbnailSize((w * scale).round(), (h * scale).round()),
              quality: 85);
          if (bytes == null) return await _status(res, HttpStatus.notFound);
          res.headers
            ..contentType = ContentType('image', 'jpeg')
            ..set('Cache-Control', 'max-age=3600');
          res.add(bytes);
          return await res.close();
        case ('GET', '/zip'):
          final share = _authorised(req, res);
          if (share == null) return;
          // Either one of the prepared parts, or the photos the friend picked.
          final picked = q['ids']?.split(',').map((id) => _file(share, id)).whereType<PreparedFile>().toList();
          if (picked != null && picked.fold<int>(0, (n, f) => n + f.size) > zipPartLimit) {
            return await _status(res, HttpStatus.requestEntityTooLarge);
          }
          final part = int.tryParse(q['part'] ?? '0') ?? 0;
          if (picked == null && (part < 0 || part >= share.parts.length)) {
            return await _status(res, HttpStatus.notFound);
          }
          final entries = _entries(picked ?? share.parts[part]);
          share.downloads += entries.length;
          notifyListeners();
          final suffix = picked != null
              ? ' (${entries.length} selected)'
              : share.parts.length > 1
                  ? ' part ${part + 1}'
                  : '';
          res.headers
            ..contentType = ContentType('application', 'zip')
            ..contentLength = zipLength(entries)
            ..set('Content-Disposition', _attachment('${share.title}$suffix.zip'));
          await res.addStream(zipStream(entries));
          return await res.close();
        case ('GET', '/' || '/index.html'):
          res.headers.contentType = ContentType.html;
          res.write(webSharePage);
          return await res.close();
        case ('GET', '/find'):
          res.headers.contentType = ContentType.html;
          res.write(findMePage);
          return await res.close();
        case ('GET', '/find/info'):
          final link = finds[q['f']];
          if (link == null) return await _status(res, HttpStatus.forbidden);
          return await _json(res, {'title': link.title, 'from': identity.alias, 'pin': link.pin != null});
        case ('POST', '/find'):
          return await _findMe(req, res, q);
        default:
          return await _status(res, HttpStatus.notFound);
      }
    } catch (e) {
      debugPrint('Web request failed: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  /// A selfie from a "Find my photos" page: who it is, and their gallery.
  Future<void> _findMe(HttpRequest req, HttpResponse res, Map<String, String> q) async {
    final link = finds[q['f']];
    if (link == null) return _status(res, HttpStatus.forbidden);
    if (link.pin != null && q['pin'] != link.pin) return _status(res, HttpStatus.unauthorized);
    final match = onSelfie;
    if (match == null) return _status(res, HttpStatus.serviceUnavailable);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > _maxSelfieBytes) return _status(res, HttpStatus.requestEntityTooLarge);
    }
    if (bytes.isEmpty) return _status(res, HttpStatus.badRequest);
    link.tries++;
    final file = File('${Directory.systemTemp.path}/selfie_${link.id}_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      await file.writeAsBytes(bytes.takeBytes(), flush: true);
      final found = await match(link, file);
      if (found == null) {
        res.statusCode = HttpStatus.notFound;
        return await _json(res, {'message': 'No match'});
      }
      if (!link.found.contains(found.name)) link.found.add(found.name);
      notifyListeners();
      return await _json(res, {'sessionId': found.share.id, 'name': found.name, 'count': found.share.files.length});
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  /// The share named by `sessionId`, if the PIN (when set) is right.
  WebShare? _authorised(HttpRequest req, HttpResponse res) {
    final share = shares[req.uri.queryParameters['sessionId']];
    if (share == null) {
      _status(res, HttpStatus.forbidden);
      return null;
    }
    if (share.pin != null && req.uri.queryParameters['pin'] != share.pin) {
      _status(res, HttpStatus.unauthorized);
      return null;
    }
    return share;
  }

  PreparedFile? _file(WebShare share, String? id) {
    final i = int.tryParse(id?.substring(1) ?? '');
    return i == null || i < 0 || i >= share.files.length ? null : share.files[i];
  }

  List<ZipEntry> _entries(List<PreparedFile> files) => [
        for (final f in files) ZipEntry(f.fileName, f.size, f.modified ?? DateTime.now(), f.open),
      ];

  static String _attachment(String name) =>
      'attachment; filename="${name.replaceAll(RegExp(r'[^\w .()-]'), '_')}"; '
      "filename*=UTF-8''${Uri.encodeComponent(name)}";

  Future<void> _json(HttpResponse res, Object body) async {
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> _status(HttpResponse res, int code) async {
    res.statusCode = code;
    await res.close();
  }

  /// A tile with the file's extension, for files that aren't photos.
  Future<void> _fileTile(HttpResponse res, PreparedFile f) async {
    final dot = f.fileName.lastIndexOf('.');
    final ext = dot < 0 ? 'FILE' : f.fileName.substring(dot + 1).toUpperCase();
    final label = const HtmlEscape().convert(ext.length > 5 ? ext.substring(0, 5) : ext);
    res.headers
      ..contentType = ContentType('image', 'svg+xml')
      ..set('Cache-Control', 'max-age=3600');
    res.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">'
        '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#FF8A5C"/><stop offset="1" stop-color="#6E5BFF"/></linearGradient></defs>'
        '<rect width="120" height="120" fill="url(#g)"/>'
        '<path d="M42 28h26l14 14v50H42z" fill="#fff" opacity=".92"/><path d="M68 28v14h14" fill="#ddd"/>'
        '<text x="62" y="76" font-family="sans-serif" font-size="13" font-weight="700" '
        'text-anchor="middle" fill="#6E5BFF">$label</text></svg>');
    await res.close();
  }
}
