import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// The chips that can run the face model.
enum Accel {
  cpu('CPU'),
  gpu('GPU'),
  npu('NPU');

  const Accel(this.label);

  final String label;

  static Accel? byName(Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }
}

/// What Settings asks for: the fastest chip that works, or one in particular.
enum AccelChoice {
  auto,
  cpu,
  gpu,
  npu;

  /// The one chip asked for; null to pick the fastest.
  Accel? get only => switch (this) {
        auto => null,
        cpu => Accel.cpu,
        gpu => Accel.gpu,
        npu => Accel.npu,
      };

  static AccelChoice byName(String? name) => values.firstWhere((v) => v.name == name, orElse: () => auto);
}

/// A GPU or NPU has to beat the CPU by this much to be worth its start-up
/// time (a second or so each time the app starts scanning).
const _worthIt = 0.9;

/// What's been learned about this phone's chips. Kept in a small file so
/// each chip is tried out once, and again after a system update or a new
/// model ([key] changes).
class AccelState {
  AccelState(this.key, {Map<Accel, double>? ms, Set<Accel>? bad, this.trying})
      : ms = ms ?? {},
        bad = bad ?? {};

  final String key;

  /// Milliseconds a face, for each chip that gave the right fingerprints.
  final Map<Accel, double> ms;

  /// Chips that wouldn't start, gave different fingerprints, or crashed.
  final Set<Accel> bad;

  /// The chip being tried for the first time right now. Still set when the
  /// app next starts: the try took the whole app down.
  Accel? trying;

  bool tried(Accel a) => ms.containsKey(a) || bad.contains(a);

  /// The quickest chip that works; the CPU until others are measured.
  Accel get best {
    final cpu = ms[Accel.cpu];
    var pick = Accel.cpu;
    var time = cpu == null ? double.infinity : cpu * _worthIt;
    for (final a in const [Accel.npu, Accel.gpu]) {
      final t = ms[a];
      if (t == null || bad.contains(a) || t >= time) continue;
      pick = a;
      time = t;
    }
    return pick;
  }

  /// A try that never finished crashed the app: don't go there again.
  /// True if there was one.
  bool settleCrash() {
    final crashed = trying;
    if (crashed == null) return false;
    bad.add(crashed);
    ms.remove(crashed);
    trying = null;
    return true;
  }

  /// Forgets what's known about [a], so it's tried afresh.
  void forget(Accel a) {
    bad.remove(a);
    ms.remove(a);
    if (trying == a) trying = null;
  }

  Map<String, Object?> toJson() => {
        'key': key,
        'ms': {for (final e in ms.entries) e.key.name: e.value},
        'bad': [for (final a in bad) a.name],
        'trying': trying?.name,
      };

  /// A fresh state when [json] is for another [key], or unreadable.
  factory AccelState.fromJson(Object? json, String key) {
    if (json is! Map || json['key'] != key) return AccelState(key);
    final state = AccelState(key, trying: Accel.byName(json['trying']));
    if (json['ms'] case final Map times) {
      for (final e in times.entries) {
        final a = Accel.byName(e.key);
        if (a != null && e.value is num) state.ms[a] = (e.value as num).toDouble();
      }
    }
    if (json['bad'] case final List bad) {
      state.bad.addAll(bad.map(Accel.byName).nonNulls);
    }
    return state;
  }

  /// Read without waiting: the try-out runs in a background isolate.
  static AccelState read(String path, String key) {
    try {
      return AccelState.fromJson(jsonDecode(File(path).readAsStringSync()), key);
    } catch (_) {
      return AccelState(key);
    }
  }

  /// Written straight to disk, so a crash right after can't lose it.
  void write(String path) {
    try {
      File(path).writeAsStringSync(jsonEncode(toJson()), flush: true);
    } catch (_) {
      // Nowhere to keep it: the chips are tried again next time.
    }
  }
}

/// Where [AccelState] is kept.
Future<String> accelStatePath() async => p.join((await getApplicationSupportDirectory()).path, 'face_chips.json');

/// Changes with the model and the system: a new driver deserves a new try.
String accelStateKey(String modelId) => '$modelId|${Platform.operatingSystem}|${Platform.operatingSystemVersion}';

// TensorFlow Lite's GPU options, which the package takes as plain numbers.
const _gpuSustainedSpeed = 1;
const _gpuPriorityAuto = 0;
const _gpuPriorityMinLatency = 2;
const _gpuFlagQuant = 1;
const _gpuFlagOpenClOnly = 2;

/// A model opened on one chip. [close] it when done.
class OpenModel {
  OpenModel._(this.interpreter, this._delegate);

  final Interpreter interpreter;
  final Delegate? _delegate;

  /// [model] on [accel]. Throws where the chip or its driver isn't there,
  /// or can't run this model.
  factory OpenModel(Uint8List model, Accel accel, {int threads = 4}) {
    final options = InterpreterOptions()..threads = threads;
    Delegate? delegate;
    try {
      switch (accel) {
        case Accel.cpu:
          break;
        case Accel.gpu:
          if (!Platform.isAndroid) throw UnsupportedError('No GPU support on this system');
          // Half-precision maths, tuned for many runs. OpenCL only: the
          // OpenGL fallback must stay on one thread, which a Dart isolate
          // can't promise.
          final gpu = GpuDelegateOptionsV2(
            isPrecisionLossAllowed: true,
            inferencePreference: _gpuSustainedSpeed,
            inferencePriority1: _gpuPriorityMinLatency,
            inferencePriority2: _gpuPriorityAuto,
            inferencePriority3: _gpuPriorityAuto,
            experimentalFlags: const [_gpuFlagQuant, _gpuFlagOpenClOnly],
          );
          try {
            delegate = GpuDelegateV2(options: gpu);
          } finally {
            gpu.delete();
          }
          options.addDelegate(delegate);
        case Accel.npu:
          if (!Platform.isAndroid) throw UnsupportedError('No NPU support on this system');
          // Android's Neural Networks API hands the model to the phone's
          // neural chip (or its DSP) when the maker ships a driver for it.
          options.useNnApiForAndroid = true;
      }
      return OpenModel._(Interpreter.fromBuffer(model, options: options), delegate);
    } catch (_) {
      delegate?.delete();
      rethrow;
    } finally {
      options.delete();
    }
  }

  void close() {
    interpreter.close();
    _delegate?.delete();
  }
}
