import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/share/client.dart';
import 'package:photo_organizer/share/tls.dart';

void main() {
  test('our HTTPS certificate works and clients pin it by fingerprint', () async {
    final tls = TlsIdentity.generate();
    expect(tls.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));

    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls.context());
    server.listen((req) async {
      req.response.write('{"ok":true}');
      await req.response.close();
    });
    final url = Uri.parse('https://127.0.0.1:${server.port}/api/localsend/v2/info');

    // Right fingerprint: connects.
    final good = lsHttpClient(fingerprint: tls.fingerprint);
    final req = await good.getUrl(url);
    final res = await req.close();
    expect(jsonDecode(await utf8.decodeStream(res)), {'ok': true});
    good.close(force: true);

    // Someone else's fingerprint: refused.
    final other = TlsIdentity.generate();
    final bad = lsHttpClient(fingerprint: other.fingerprint);
    await expectLater(() async => (await bad.getUrl(url)).close(), throwsA(isA<HandshakeException>()));
    bad.close(force: true);

    await server.close(force: true);
  });
}
