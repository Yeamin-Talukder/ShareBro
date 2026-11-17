import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/people_sync.dart';
import 'client.dart';
import 'net.dart';
import 'protocol.dart';

/// ShareBro's people-swap endpoint, on the same HTTPS port as sending.
const peopleApi = '/api/sharebro/v1/people';

/// How long a request waits for someone to tap Accept.
const _answerWithin = Duration(minutes: 2);

/// Someone asked to swap face data with this device.
class IncomingPeopleRequest {
  IncomingPeopleRequest({required this.from, required this.code, required this.people});

  /// The other device's name.
  final String from;

  /// The 4-digit code the other device is showing; the two must match.
  final String code;

  /// Who they'd send (name and face crop), to show before accepting.
  final List<SyncPerson> people;

  final Completer<bool> _answer = Completer();
  bool get answered => _answer.isCompleted;

  void answer(bool yes) {
    if (!_answer.isCompleted) _answer.complete(yes);
  }
}

/// How a swap this device started went.
enum SwapStatus { done, declined, busy, notSharebro, failed }

class SwapOutcome {
  SwapOutcome(this.status, [this.result]);

  final SwapStatus status;

  /// What this device took in (when [status] is done).
  final PeopleSyncResult? result;
}

/// Both ends of a people swap. A swap goes both ways in one exchange: the
/// device that starts it sends its people; the other device, once someone
/// accepts there, takes them in and answers with its own.
class PeopleSyncHub extends ChangeNotifier {
  PeopleSyncHub(this.identity, {required this.build, required this.take});

  final ShareIdentity identity;

  /// This device's people, as sent.
  final Future<PeoplePackage> Function() build;

  /// Takes another device's people in (matching, naming, regrouping).
  final Future<PeopleSyncResult> Function(PeoplePackage package) take;

  /// A request waiting for Accept / Decline.
  IncomingPeopleRequest? pending;

  /// What the last accepted request brought in (for the "done" message).
  PeopleSyncResult? lastIncoming;

  /// A fresh code for a swap this device starts.
  static String newCode() => (1000 + math.Random.secure().nextInt(9000)).toString();

  // ---- Starting a swap ----

  /// Sends this device's people to [device] and takes its people back.
  /// Waits (up to a couple of minutes) for someone to accept there.
  Future<SwapOutcome> swapWith(LsDevice device, String code) async {
    final mine = await build();
    final client = lsHttpClient(fingerprint: device.fingerprint, identity: identity.tls);
    try {
      final res = await postJson(
        client,
        Uri(scheme: 'https', host: device.ip, port: device.info.port, path: '$peopleApi/swap'),
        {'alias': identity.alias, 'fingerprint': identity.fingerprint, 'code': code, 'package': mine.toJson()},
        timeout: _answerWithin + const Duration(seconds: 30),
      );
      switch (res.status) {
        case HttpStatus.ok:
          final theirs = PeoplePackage.fromJson(res.json?['package']);
          if (theirs == null) return SwapOutcome(SwapStatus.failed);
          return SwapOutcome(SwapStatus.done, await take(theirs));
        case HttpStatus.forbidden || HttpStatus.requestTimeout:
          return SwapOutcome(SwapStatus.declined);
        case HttpStatus.conflict:
          return SwapOutcome(SwapStatus.busy);
        case HttpStatus.notFound:
          return SwapOutcome(SwapStatus.notSharebro);
        default:
          return SwapOutcome(SwapStatus.failed);
      }
    } catch (e) {
      debugPrint('People swap failed: $e');
      return SwapOutcome(SwapStatus.failed);
    } finally {
      client.close(force: true);
    }
  }

  // ---- Answering one ----

  /// Answers people-swap requests. Returns false for anything else.
  Future<bool> handle(HttpRequest req, String? ip) async {
    if (req.method != 'POST' || req.uri.path != '$peopleApi/swap') return false;
    final res = req.response;
    Map<String, dynamic> body;
    try {
      // Fingerprints for a few hundred people fit easily; refuse anything huge.
      if (req.contentLength > 64 * 1024 * 1024) return await _reply(res, HttpStatus.requestEntityTooLarge);
      body = (jsonDecode(await utf8.decodeStream(req)) as Map).cast<String, dynamic>();
    } catch (_) {
      return await _reply(res, HttpStatus.badRequest);
    }
    final theirs = PeoplePackage.fromJson(body['package']);
    final code = body['code'];
    if (theirs == null || code is! String || !RegExp(r'^\d{4}$').hasMatch(code)) {
      return _reply(res, HttpStatus.badRequest);
    }
    if (pending != null) return _reply(res, HttpStatus.conflict);
    final alias = body['alias'];
    final request = IncomingPeopleRequest(
      from: alias is String && alias.trim().isNotEmpty ? alias.trim() : theirs.from,
      code: code,
      people: theirs.people,
    );
    pending = request;
    notifyListeners();
    bool yes;
    try {
      yes = await request._answer.future.timeout(_answerWithin, onTimeout: () => false);
    } finally {
      pending = null;
      notifyListeners();
    }
    if (!yes) return _reply(res, HttpStatus.forbidden);
    try {
      lastIncoming = await take(theirs);
      notifyListeners();
      final mine = await build();
      return await _reply(res, HttpStatus.ok, {'package': mine.toJson()});
    } catch (e) {
      debugPrint('Taking people in failed: $e');
      return await _reply(res, HttpStatus.internalServerError);
    }
  }

  Future<bool> _reply(HttpResponse res, int status, [Object? json]) async {
    res.statusCode = status;
    if (json != null) {
      res.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(json));
      res.contentLength = bytes.length;
      res.add(Uint8List.fromList(bytes));
    }
    await res.close();
    return true;
  }
}
