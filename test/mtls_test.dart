import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/share/client.dart';
import 'package:photo_organizer/share/net.dart';
import 'package:photo_organizer/share/tls.dart';

void main() {
  // Current LocalSend versions require the sender's own certificate (mutual
  // TLS) and check its SHA-256 against the fingerprint the sender claims.
  test('senders show their certificate, and it matches their fingerprint', () async {
    final receiver = TlsIdentity.generate();
    final me = ShareIdentity('ShareBro', TlsIdentity.generate());
    final ctx = receiver.context()..setTrustedCertificatesBytes(me.tls.certificatePem.codeUnits);
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx, requestClientCertificate: true);
    server.listen((req) async {
      final cert = req.certificate;
      final claimed = (jsonDecode(await utf8.decodeStream(req)) as Map)['fingerprint'];
      final proven = cert != null && sha256.convert(cert.der).toString().toUpperCase() == claimed;
      req.response.statusCode = proven ? 200 : 403;
      await req.response.close();
    });
    final url = Uri.parse('https://127.0.0.1:${server.port}/api/localsend/v2/register');

    final withCert = lsHttpClient(fingerprint: receiver.fingerprint, identity: me.tls);
    expect((await postJson(withCert, url, me.info().toJson())).status, 200);
    withCert.close(force: true);

    final without = lsHttpClient(fingerprint: receiver.fingerprint);
    expect((await postJson(without, url, me.info().toJson())).status, 403);
    without.close(force: true);

    await server.close(force: true);
  });
}
