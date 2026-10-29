import 'dart:async';
import 'dart:io';

import 'client.dart';
import 'net.dart';
import 'prepare.dart';
import 'protocol.dart';

/// How a send ended.
enum SendOutcome { done, nothingNeeded, declined, needsPin, busy, failed, cancelled }

class SendResult {
  SendResult(this.outcome, {this.sent = const [], this.failed = const [], this.message});

  final SendOutcome outcome;

  /// Asset ids that arrived.
  final List<String> sent;
  final List<String> failed;
  final String? message;
}

/// Lets the UI stop a send part-way.
class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// Photos sent at the same time to one device.
const _parallel = 3;

/// Waiting for the friend to tap "Accept" on their phone.
const _acceptTimeout = Duration(minutes: 3);

/// Sends files to a LocalSend device: `prepare-upload` (the friend accepts),
/// then each file with `upload`, then `cancel` if stopped early.
class LsSender {
  LsSender(this.identity);

  final ShareIdentity identity;

  Future<SendResult> send({
    required LsDevice device,
    required List<PreparedFile> files,
    String? pin,
    CancelToken? cancel,
    void Function(int sentBytes, int totalBytes, int filesDone)? onProgress,
    void Function()? onAccepted,
  }) async {
    final client = lsHttpClient(fingerprint: device.fingerprint)
      ..connectionTimeout = const Duration(seconds: 8);
    final byId = {for (var i = 0; i < files.length; i++) 'p$i': files[i]};
    try {
      final LsResponse prep;
      try {
        prep = await postJson(
          client,
          device.uri('/prepare-upload', pin == null ? null : {'pin': pin}),
          {
            'info': identity.info(download: true).toJson(),
            'files': {
              for (final e in byId.entries)
                e.key: LsFile(
                  id: e.key,
                  fileName: e.value.fileName,
                  size: e.value.size,
                  fileType: e.value.mime,
                  preview: e.value.preview,
                  modified: e.value.modified,
                ).toJson(),
            },
          },
          timeout: _acceptTimeout,
        );
      } on TimeoutException {
        return SendResult(SendOutcome.declined, message: 'No answer from ${device.alias}');
      }
      switch (prep.status) {
        case 204:
          return SendResult(SendOutcome.nothingNeeded, sent: [for (final f in files) f.assetId]);
        case 401:
          return SendResult(SendOutcome.needsPin);
        case 403:
          return SendResult(SendOutcome.declined, message: '${device.alias} declined');
        case 409:
        case 429:
          return SendResult(SendOutcome.busy, message: '${device.alias} is busy with another transfer');
      }
      final json = prep.json;
      if (!prep.ok || json == null) {
        return SendResult(SendOutcome.failed, message: 'Unexpected reply (${prep.status})');
      }
      onAccepted?.call();
      final sessionId = json['sessionId'] as String;
      // The friend may accept only some of the files.
      final tokens = (json['files'] as Map).cast<String, String>();
      final total = tokens.keys.fold<int>(0, (n, id) => n + (byId[id]?.size ?? 0));
      var sentBytes = 0, filesDone = 0;
      final sent = <String>[], failed = <String>[];
      final queue = tokens.entries.toList();

      Future<void> worker() async {
        while (queue.isNotEmpty && !(cancel?.cancelled ?? false)) {
          final entry = queue.removeAt(0);
          final file = byId[entry.key];
          if (file == null) continue;
          var fileBytes = 0;
          var ok = false;
          for (var attempt = 0; attempt < 3 && !ok && !(cancel?.cancelled ?? false); attempt++) {
            sentBytes -= fileBytes;
            fileBytes = 0;
            try {
              final req = await client.postUrl(device.uri('/upload', {
                'sessionId': sessionId,
                'fileId': entry.key,
                'token': entry.value,
              }));
              req.contentLength = file.size;
              req.headers.contentType = ContentType.parse(file.mime);
              await req.addStream(file.open().map((chunk) {
                fileBytes += chunk.length;
                sentBytes += chunk.length;
                onProgress?.call(sentBytes, total, filesDone);
                return chunk;
              }));
              final res = await req.close();
              await res.drain<void>();
              ok = res.statusCode >= 200 && res.statusCode < 300;
              // A wrong token or a finished session won't get better by retrying.
              if (res.statusCode == 403 || res.statusCode == 409) break;
            } catch (_) {
              await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
            }
          }
          (ok ? sent : failed).add(file.assetId);
          filesDone++;
          onProgress?.call(sentBytes, total, filesDone);
        }
      }

      await Future.wait([for (var w = 0; w < _parallel; w++) worker()]);

      if (cancel?.cancelled ?? false) {
        try {
          await postJson(client, device.uri('/cancel', {'sessionId': sessionId}), null,
              timeout: const Duration(seconds: 3));
        } catch (_) {}
        return SendResult(SendOutcome.cancelled, sent: sent, failed: failed);
      }
      return SendResult(
        failed.isEmpty ? SendOutcome.done : SendOutcome.failed,
        sent: sent,
        failed: failed,
        message: failed.isEmpty ? null : '${failed.length} files didn\'t arrive',
      );
    } on SocketException catch (e) {
      return SendResult(SendOutcome.failed, message: 'Can\'t reach ${device.alias} (${e.message})');
    } catch (e) {
      return SendResult(SendOutcome.failed, message: '$e');
    } finally {
      client.close(force: true);
    }
  }
}
