import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/db.dart' show NewFace;
import 'package:photo_organizer/share/scan_helper.dart';

/// The computer's side of "Scan with my computer", driven over real HTTP
/// the way a phone would: progress and speed it reports, and face results
/// it may remember only as long as the phone allows.
void main() {
  late Directory root;
  late HttpServer server;
  late ScanHelperHub hub;
  late HttpClient http;
  var analyzed = 0;
  final settings = <String, String>{};

  NewFace face() => NewFace(
        left: .1,
        top: .2,
        width: .3,
        height: .3,
        embedding: Float32List(512)..[0] = 1,
        thumb: Uint8List.fromList([1, 2, 3]),
        sharpness: 5,
      );

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$scanApi/$path');

  Future<(int, Map<String, dynamic>?)> post(String path, List<int> body, Map<String, String> headers) async {
    final req = await http.postUrl(url(path));
    headers.forEach(req.headers.set);
    req.add(body);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text.isEmpty ? null : (jsonDecode(text) as Map).cast<String, dynamic>());
  }

  /// Pairs (answering Allow on the computer) and starts a session.
  Future<String> hello({int keep = 0, String? key}) async {
    void allow() => hub.pending?.answer(true);
    hub.addListener(allow);
    final (status, json) = await post(
        'hello',
        utf8.encode(jsonEncode({
          'alias': 'Test phone',
          'fingerprint': 'phone-fp',
          'model': 'model-1',
          'code': '1234',
          'key': ?key,
          'keep': keep,
        })),
        {'content-type': 'application/json'});
    hub.removeListener(allow);
    expect(status, 200);
    return json!['token'] as String;
  }

  Future<int> photo(String token, List<int> jpeg, {int keep = 0, int done = 10, int total = 100}) async {
    final (status, json) = await post('faces', jpeg, {
      'x-scan-token': token,
      'x-scan-done': '$done',
      'x-scan-total': '$total',
      'x-scan-rate': '12.5',
      'x-scan-keep': '$keep',
      'x-scan-album': Uri.encodeComponent('Beach trip'),
    });
    expect(status, 200);
    return (json!['faces'] as List).length;
  }

  Directory resultsDir() => Directory('${root.path}${Platform.pathSeparator}scan_helper_results');
  List<File> remembered() =>
      resultsDir().existsSync() ? resultsDir().listSync(recursive: true).whereType<File>().toList() : [];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_helper_test');
    analyzed = 0;
    settings.clear();
    hub = ScanHelperHub(
      readSetting: (k) async => settings[k],
      writeSetting: (k, v) async => settings[k] = v,
      faceModel: 'model-1',
      analyze: (jpeg) async {
        analyzed++;
        return [face()];
      },
      alias: () => 'Test PC',
      resultsRoot: () async => root,
    );
    await hub.load();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => hub.handle(req, '127.0.0.1'));
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('shows the phone\'s progress, speed and what is left', () async {
    final token = await hello();
    await photo(token, [1, 2, 3], done: 40, total: 100);
    final s = hub.sessions[token]!;
    expect(s.photos, 1);
    expect(s.faces, 1);
    expect(s.phoneDone, 40);
    expect(s.phoneTotal, 100);
    expect(s.remaining, 60);
    expect(s.phoneRate, 12.5);
    expect(s.timeLeft, const Duration(seconds: 5));
    expect(s.album, 'Beach trip');
    expect(s.bytes, 3);
    expect(s.rate, greaterThan(0));
    expect(s.share, closeTo(1 / 40, 1e-9));
  });

  test('keeps nothing unless the phone allows it', () async {
    final token = await hello();
    await photo(token, [1, 2, 3]);
    await photo(token, [1, 2, 3]);
    expect(analyzed, 2);
    expect(remembered(), isEmpty);
  });

  test('answers a repeated photo from memory while allowed', () async {
    final token = await hello(keep: 7);
    expect(await photo(token, [9, 9, 9], keep: 7), 1);
    expect(await photo(token, [9, 9, 9], keep: 7), 1);
    expect(analyzed, 1, reason: 'the second time comes from memory');
    final s = hub.sessions[token]!;
    expect(s.remembered, 1);
    expect(s.keptCount, 1);
    expect(remembered(), hasLength(1));
    // Only face results are stored, never the photo.
    final saved = remembered().single.readAsStringSync();
    expect(saved, isNot(contains(base64Encode([9, 9, 9]))));
  });

  test('the phone turning it off deletes what was remembered', () async {
    final token = await hello(keep: 30);
    await photo(token, [5, 5], keep: 30);
    expect(remembered(), hasLength(1));
    await photo(token, [6, 6], keep: 0);
    expect(remembered(), isEmpty);
    expect(hub.sessions[token]!.keepDays, 0);
    // And the next repeat is scanned again.
    await photo(token, [5, 5], keep: 0);
    expect(analyzed, 3);
  });

  test('results past the phone\'s period are not used', () async {
    final token = await hello(keep: 1);
    await photo(token, [7, 7], keep: 1);
    final file = remembered().single;
    await file.setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    await photo(token, [7, 7], keep: 1);
    expect(analyzed, 2);
  });

  test('forgetting all phones deletes every remembered result', () async {
    final token = await hello(keep: 7);
    await photo(token, [8], keep: 7);
    expect(remembered(), isNotEmpty);
    await hub.forgetAll();
    expect(resultsDir().existsSync(), isFalse);
  });
}
