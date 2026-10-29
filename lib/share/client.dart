import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// HTTP(S) client for talking to LocalSend devices. LocalSend devices use
/// self-made certificates; we accept one only if its SHA-256 matches the
/// fingerprint the device announced (when the fingerprint is a hash).
HttpClient lsHttpClient({String? fingerprint}) {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4)
    ..idleTimeout = const Duration(seconds: 20);
  client.badCertificateCallback = (cert, host, port) {
    final expected = fingerprint?.toLowerCase();
    if (expected == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      // Not a certificate hash (plain-HTTP style id): trust on first use.
      return true;
    }
    return sha256.convert(cert.der).toString() == expected;
  };
  return client;
}

class LsResponse {
  LsResponse(this.status, this.body);

  final int status;
  final Object? body;

  bool get ok => status >= 200 && status < 300;
  Map<String, dynamic>? get json => body is Map<String, dynamic> ? body as Map<String, dynamic> : null;
}

/// POSTs JSON and decodes a JSON reply (if any).
Future<LsResponse> postJson(
  HttpClient client,
  Uri uri,
  Object? body, {
  Duration timeout = const Duration(seconds: 6),
}) async {
  final req = await client.postUrl(uri).timeout(timeout);
  req.headers.contentType = ContentType.json;
  // Sized, not chunked: LocalSend's own client always sends a length, and
  // some receivers drop chunked requests.
  final bytes = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
  req.contentLength = bytes.length;
  if (bytes.isNotEmpty) req.add(bytes);
  final res = await req.close().timeout(timeout);
  final text = await res.transform(utf8.decoder).join().timeout(timeout);
  Object? decoded;
  if (text.isNotEmpty) {
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = text;
    }
  }
  return LsResponse(res.statusCode, decoded);
}
