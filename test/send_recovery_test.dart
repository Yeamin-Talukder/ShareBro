import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/share/net.dart';
import 'package:photo_organizer/share/prepare.dart';
import 'package:photo_organizer/share/protocol.dart';
import 'package:photo_organizer/share/sender.dart';
import 'package:photo_organizer/share/tls.dart';

/// A LocalSend-style receiver that misbehaves on purpose.
class _FlakyReceiver {
  _FlakyReceiver._(this.server, this.tls);

  final HttpServer server;
  final TlsIdentity tls;
  int prepareCalls = 0, uploadCalls = 0;
  bool sawChunkedJson = false;
  final Map<String, int> received = {};

  /// Drop the first prepare-upload; drop each file's first upload partway.
  bool dropFirstPrepare = true, dropFirstUploads = true;
  final Set<String> _dropped = {};

  static Future<_FlakyReceiver> start() async {
    final tls = TlsIdentity.generate();
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls.context());
    final r = _FlakyReceiver._(server, tls);
    server.listen(r._handle);
    return r;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path.endsWith('/prepare-upload')) {
      prepareCalls++;
      if (req.headers.chunkedTransferEncoding || req.contentLength < 0) sawChunkedJson = true;
      if (dropFirstPrepare && prepareCalls == 1) {
        // Hang up without answering: "Connection reset by peer".
        (await req.response.detachSocket()).destroy();
        return;
      }
      final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
      final files = (body['files'] as Map).keys.cast<String>();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'sessionId': 's1', 'files': {for (final f in files) f: 'tok-$f'}}));
      return req.response.close();
    }
    if (path.endsWith('/upload')) {
      uploadCalls++;
      final id = req.uri.queryParameters['fileId']!;
      if (dropFirstUploads && _dropped.add(id)) {
        // Read a little, then hang up mid-file.
        await req.take(1).drain<void>();
        (await req.response.detachSocket()).destroy();
        return;
      }
      received[id] = await req.fold<int>(0, (n, c) => n + c.length);
      return req.response.close();
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  LsDevice get device => LsDevice(
        info: LsInfo(alias: 'Energetic Avocado', fingerprint: tls.fingerprint, port: server.port, protocol: 'https'),
        ip: '127.0.0.1',
        lastSeen: DateTime.now(),
      );
}

void main() {
  late Directory tmp;
  late List<PreparedFile> files;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('send_recovery');
    files = [
      for (var i = 0; i < 4; i++)
        () {
          final f = File(p.join(tmp.path, 'IMG_$i.jpg'))..writeAsBytesSync(List.filled(200000 + i, i));
          return PreparedFile(assetId: 'a$i', fileName: 'IMG_$i.jpg', size: f.lengthSync(), mime: 'image/jpeg', file: f);
        }(),
    ];
  });
  tearDown(() => tmp.delete(recursive: true));

  test('recovers when the receiver drops the first request and each upload once', () async {
    final r = await _FlakyReceiver.start();
    final sender = LsSender(ShareIdentity('ShareBro', TlsIdentity.generate()));
    final result = await sender.send(device: r.device, files: files);
    await r.server.close(force: true);

    expect(result.outcome, SendOutcome.done, reason: result.message);
    expect(result.sent.toSet(), {'a0', 'a1', 'a2', 'a3'});
    expect(r.prepareCalls, 2, reason: 'one quick retry after the dropped connection');
    expect(r.received, {for (var i = 0; i < 4; i++) 'p$i': 200000 + i});
    expect(r.sawChunkedJson, isFalse, reason: 'JSON is sent with a Content-Length, like LocalSend');
  });

  test('a receiver that is not there gets a clear message, not a raw error', () async {
    final r = await _FlakyReceiver.start();
    final device = r.device;
    await r.server.close(force: true); // nothing listening any more
    final result = await LsSender(ShareIdentity('ShareBro', TlsIdentity.generate())).send(device: device, files: files);
    expect(result.outcome, SendOutcome.failed);
    expect(result.message, contains('Energetic Avocado'));
    expect(result.message, isNot(contains('Exception')));
  });

  test('errors are explained in plain words', () {
    const who = 'Maya';
    expect(explainSendError(const HttpException('Connection reset by peer'), who), contains('closed the connection'));
    expect(explainSendError(const SocketException('Connection refused'), who), contains('Open LocalSend'));
    expect(explainSendError(const SocketException('Connection timed out'), who), contains('same Wi-Fi'));
    expect(explainSendError(const HandshakeException('bad cert'), who), contains('securely'));
  });
}
