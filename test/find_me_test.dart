import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart';
import 'package:photo_organizer/share/discovery.dart';
import 'package:photo_organizer/share/net.dart';
import 'package:photo_organizer/share/receive.dart';
import 'package:photo_organizer/share/server.dart';
import 'package:photo_organizer/share/tls.dart';

/// Nothing in these requests touches the database.
class _NoDb implements AppDb {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('a selfie on a Find my photos link leads to that person\'s gallery', (tester) async {
    // Real sockets: widget tests fake every HTTP request otherwise.
    HttpOverrides.global = null;
    await tester.runAsync(() async {
      final me = ShareIdentity('Maya\'s Pixel', TlsIdentity.generate());
      final server = ShareServer(me, Discovery(me), Receiver(_NoDb()));
      await server.start();
      final tmp = await Directory.systemTemp.createTemp('find');
      var seen = 0;
      server.onSelfie = (link, selfie) async {
        seen = await selfie.length();
        // A tiny selfie stands for "nobody we know".
        if (seen < 10) return null;
        // Like the app: the same person gets the same gallery again.
        final share = server.shares[link.galleries[2]] ?? server.openShare('Leo\'s photos', const [], tmp);
        link.galleries[2] = share.id;
        return (share: share, name: 'Leo Park');
      };
      final link = server.openFind('Goa trip');
      final base = 'http://127.0.0.1:${server.webServerPort}';
      final http = HttpClient();

      Future<(int, String)> call(String method, String path, [List<int>? body]) async {
        final req = await http.openUrl(method, Uri.parse('$base$path'));
        if (body != null) req.add(body);
        final res = await req.close();
        return (res.statusCode, await utf8.decodeStream(res));
      }

      final page = await call('GET', '/find?f=${link.id}');
      expect(page.$1, 200);
      expect(page.$2, contains('Take a selfie'));

      final info = jsonDecode((await call('GET', '/find/info?f=${link.id}')).$2) as Map;
      expect(info, {'title': 'Goa trip', 'from': 'Maya\'s Pixel', 'pin': false});

      expect((await call('POST', '/find?f=${link.id}', [1, 2, 3])).$1, 404);

      final found = await call('POST', '/find?f=${link.id}', List.filled(2000, 7));
      expect(found.$1, 200);
      expect(seen, 2000);
      final j = jsonDecode(found.$2) as Map;
      expect(j['name'], 'Leo Park');
      expect(server.shares.containsKey(j['sessionId']), isTrue);
      expect(link.found, ['Leo Park']);
      expect(link.tries, 2);

      link.pin = '4821';
      expect((await call('POST', '/find?f=${link.id}', List.filled(2000, 7))).$1, 401);
      expect((await call('POST', '/find?f=${link.id}&pin=4821', List.filled(2000, 7))).$1, 200);

      // Stopping the link closes the galleries it opened.
      await server.closeFind(link.id);
      expect(server.shares, isEmpty);
      expect((await call('POST', '/find?f=${link.id}', List.filled(2000, 7))).$1, 403);

      http.close(force: true);
      await server.stop();
      await tmp.delete(recursive: true).catchError((_) => tmp);
    });
  });
}
