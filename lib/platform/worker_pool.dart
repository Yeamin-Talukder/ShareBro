import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;

/// A few long-lived background isolates for short CPU jobs (encoding a
/// thumbnail, reading EXIF). `Isolate.run` starts and tears down an
/// isolate for every call, which adds up over thousands of photos; these
/// stay up and take jobs one after another.
///
/// Jobs are closures, sent within the app's isolate group, so they may only
/// capture sendable values (numbers, strings, typed data, records…).
class WorkerPool {
  WorkerPool({int? size, this.name = 'worker'})
      : size = size ?? math.max(1, math.min(4, _cpus() - 1));

  /// Shared pool for small jobs across the app.
  static final shared = WorkerPool(name: 'shared');

  final int size;
  final String name;

  final List<_Worker> _idle = [];
  final List<_Worker> _all = [];
  final List<Completer<_Worker>> _waiting = [];
  int _starting = 0;

  /// Runs [job] on one of the pool's isolates and returns its result.
  Future<R> run<R>(FutureOr<R> Function() job) async {
    final w = await _take();
    try {
      return await w.run(job);
    } finally {
      _give(w);
    }
  }

  Future<_Worker> _take() async {
    if (_idle.isNotEmpty) return _idle.removeLast();
    if (_all.length + _starting < size) {
      _starting++;
      try {
        final w = await _Worker.start('$name-${_all.length + 1}');
        _all.add(w);
        return w;
      } finally {
        _starting--;
      }
    }
    final turn = Completer<_Worker>();
    _waiting.add(turn);
    return turn.future;
  }

  void _give(_Worker w) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(w);
    } else {
      _idle.add(w);
    }
  }

  /// Stops every isolate; jobs already running finish first.
  void close() {
    for (final w in _all) {
      w.stop();
    }
    _all.clear();
    _idle.clear();
  }
}

int _cpus() => Platform.numberOfProcessors;

class _Worker {
  _Worker(this._send, this._isolate);

  final SendPort _send;
  final Isolate _isolate;

  static Future<_Worker> start(String name) async {
    final hello = ReceivePort();
    final isolate = await Isolate.spawn(_main, hello.sendPort, debugName: name);
    final send = await hello.first as SendPort;
    return _Worker(send, isolate);
  }

  Future<R> run<R>(FutureOr<R> Function() job) async {
    final reply = ReceivePort();
    _send.send((job, reply.sendPort));
    final result = await reply.first;
    reply.close();
    if (result case (Object error, StackTrace stack)) {
      Error.throwWithStackTrace(error, stack);
    }
    return (result as (R,)).$1;
  }

  void stop() {
    _send.send(null);
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  static void _main(SendPort hello) {
    final inbox = ReceivePort();
    hello.send(inbox.sendPort);
    inbox.listen((msg) async {
      if (msg == null) {
        inbox.close();
        return;
      }
      final (job, reply) = msg as (FutureOr<Object?> Function(), SendPort);
      try {
        reply.send((await job(),));
      } catch (e, s) {
        reply.send((e, s));
      }
    });
  }
}
