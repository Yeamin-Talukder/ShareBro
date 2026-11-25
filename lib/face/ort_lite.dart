// The onnxruntime plugin's own API converts tensors number by number
// through Dart lists and keeps its session options private; this talks to
// the same runtime through the plugin's generated bindings instead.
// ignore_for_file: implementation_imports
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart' show OrtEnv;
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart' as bg;

/// A lean ONNX Runtime session for float models on desktop: tensors are
/// copied in and out as whole blocks, and it runs on the graphics chip when
/// the bundled runtime and the computer support it: DirectML on Windows,
/// Core ML on a Mac (which also uses Apple's Neural Engine).
class LiteSession {
  LiteSession._(this._session, this._options, this._memory, this._inputNames, this._outputNames, this.onGpu);

  final ffi.Pointer<bg.OrtSession> _session;
  final ffi.Pointer<bg.OrtSessionOptions> _options;
  final ffi.Pointer<bg.OrtMemoryInfo> _memory;
  final List<ffi.Pointer<Utf8>> _inputNames, _outputNames;

  /// Running on the graphics chip rather than the CPU.
  final bool onGpu;

  /// Reused input buffer (grown when a bigger input comes).
  ffi.Pointer<ffi.Float> _in = ffi.nullptr;
  int _inCapacity = 0;

  static ffi.Pointer<bg.OrtApi> get _api => OrtEnv.instance.ortApiPtr;

  /// Opens [model] on the graphics chip (DirectML, or Core ML on a Mac);
  /// throws if the runtime, the driver or the model can't use it.
  static LiteSession openGpu(Uint8List model) => _open(model, threads: 1, gpu: true);

  /// Opens [model]. With [gpu], tries DirectML first and falls back to the
  /// CPU if the runtime, the driver or the model can't use it.
  ///
  /// Without [spin], idle CPU threads sleep instead of spin-waiting for the
  /// next run: slower alone, but they stop taking CPU from other work.
  static LiteSession open(Uint8List model, {required int threads, bool gpu = false, bool spin = true}) {
    if (gpu) {
      try {
        return _open(model, threads: threads, gpu: true, spin: spin);
      } catch (_) {
        // No DirectML build, no suitable graphics chip, or an old driver.
      }
    }
    return _open(model, threads: threads, gpu: false, spin: spin);
  }

  static LiteSession _open(Uint8List model, {required int threads, required bool gpu, bool spin = true}) {
    final api = _api.ref;
    final optionsOut = calloc<ffi.Pointer<bg.OrtSessionOptions>>();
    _check(api.CreateSessionOptions.asFunction<bg.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<bg.OrtSessionOptions>>)>()(
        optionsOut));
    final options = optionsOut.value;
    calloc.free(optionsOut);
    final data = malloc<ffi.Uint8>(model.length);
    try {
      _check(api.SetIntraOpNumThreads.asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(
          options, threads));
      _check(api.SetSessionGraphOptimizationLevel
          .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(options, 99));
      if (!spin) {
        final key = 'session.intra_op.allow_spinning'.toNativeUtf8(), off = '0'.toNativeUtf8();
        try {
          _check(api.AddSessionConfigEntry.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Char>)>()(options, key.cast(), off.cast()));
        } finally {
          malloc.free(key);
          malloc.free(off);
        }
      }
      if (gpu && Platform.isMacOS) {
        // Core ML hands what it can to the Mac's graphics chip and Neural
        // Engine; anything it can't run stays on the CPU.
        _check(_appendCoreML()(options, 0));
      } else if (gpu) {
        if (!Platform.isWindows) throw UnsupportedError('No graphics-chip runtime on this system');
        // DirectML wants one run at a time and no memory-pattern planning.
        _check(api.DisableMemPattern.asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>)>()(options));
        _check(api.SetSessionExecutionMode
            .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(options, 0));
        _check(_appendDirectML()(options, 0));
      }
      data.asTypedList(model.length).setAll(0, model);
      final sessionOut = calloc<ffi.Pointer<bg.OrtSession>>();
      try {
        _check(api.CreateSessionFromArray.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtEnv>, ffi.Pointer<ffi.Void>, int,
                ffi.Pointer<bg.OrtSessionOptions>, ffi.Pointer<ffi.Pointer<bg.OrtSession>>)>()(
            OrtEnv.instance.ptr, data.cast(), model.length, options, sessionOut));
        final session = sessionOut.value;
        final memoryOut = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
        _check(api.CreateCpuMemoryInfo.asFunction<
            bg.OrtStatusPtr Function(int, int, ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(1, 0, memoryOut));
        final memory = memoryOut.value;
        calloc.free(memoryOut);
        return LiteSession._(session, options, memory, _names(session, input: true), _names(session, input: false), gpu);
      } finally {
        calloc.free(sessionOut);
      }
    } catch (_) {
      api.ReleaseSessionOptions.asFunction<void Function(ffi.Pointer<bg.OrtSessionOptions>)>()(options);
      rethrow;
    } finally {
      malloc.free(data);
    }
  }

  /// Core ML's hook, in the Mac runtime the onnxruntime plugin bundles.
  static int Function(ffi.Pointer<bg.OrtSessionOptions>, int) _appendCoreML() {
    final lib = ffi.DynamicLibrary.open('libonnxruntime.1.15.1.dylib');
    final fn = lib.lookupFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, ffi.Uint32),
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>('OrtSessionOptionsAppendExecutionProvider_CoreML');
    return (options, flags) => fn(options, flags).address;
  }

  /// DirectML's hook, only in the runtime's DirectML build.
  static int Function(ffi.Pointer<bg.OrtSessionOptions>, int) _appendDirectML() {
    final lib = ffi.DynamicLibrary.open('onnxruntime.dll');
    final fn = lib.lookupFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, ffi.Int),
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>('OrtSessionOptionsAppendExecutionProvider_DML');
    return (options, device) => fn(options, device).address;
  }

  static List<ffi.Pointer<Utf8>> _names(ffi.Pointer<bg.OrtSession> session, {required bool input}) {
    final api = _api.ref;
    final count = calloc<ffi.Size>();
    final allocator = calloc<ffi.Pointer<bg.OrtAllocator>>();
    final name = calloc<ffi.Pointer<ffi.Char>>();
    try {
      _check((input ? api.SessionGetInputCount : api.SessionGetOutputCount)
          .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSession>, ffi.Pointer<ffi.Size>)>()(session, count));
      _check(api.GetAllocatorWithDefaultOptions
          .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<bg.OrtAllocator>>)>()(allocator));
      final out = <ffi.Pointer<Utf8>>[];
      for (var i = 0; i < count.value; i++) {
        _check((input ? api.SessionGetInputName : api.SessionGetOutputName).asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSession>, int, ffi.Pointer<bg.OrtAllocator>,
                ffi.Pointer<ffi.Pointer<ffi.Char>>)>()(session, i, allocator.value, name));
        // Our own copy; the runtime's is freed with its allocator.
        out.add(name.value.cast<Utf8>().toDartString().toNativeUtf8());
        _check(api.AllocatorFree.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtAllocator>, ffi.Pointer<ffi.Void>)>()(allocator.value, name.value.cast()));
      }
      return out;
    } finally {
      calloc.free(count);
      calloc.free(allocator);
      calloc.free(name);
    }
  }

  /// Runs the model on one float input of [shape]; returns every output,
  /// flattened.
  List<Float32List> run(Float32List input, List<int> shape) {
    final api = _api.ref;
    if (input.length > _inCapacity) {
      if (_inCapacity > 0) malloc.free(_in);
      _in = malloc<ffi.Float>(input.length);
      _inCapacity = input.length;
    }
    _in.asTypedList(input.length).setAll(0, input);
    final dims = calloc<ffi.Int64>(shape.length);
    final valueOut = calloc<ffi.Pointer<bg.OrtValue>>();
    final inNames = calloc<ffi.Pointer<ffi.Char>>(_inputNames.length);
    final outNames = calloc<ffi.Pointer<ffi.Char>>(_outputNames.length);
    final outputs = calloc<ffi.Pointer<bg.OrtValue>>(_outputNames.length);
    try {
      dims.asTypedList(shape.length).setAll(0, shape);
      _check(api.CreateTensorWithDataAsOrtValue.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtMemoryInfo>, ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Int64>, int, int,
              ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(_memory, _in.cast(), input.length * 4, dims, shape.length, 1, valueOut));
      final value = valueOut.value;
      for (var i = 0; i < _inputNames.length; i++) {
        inNames[i] = _inputNames[i].cast();
      }
      for (var i = 0; i < _outputNames.length; i++) {
        outNames[i] = _outputNames[i].cast();
      }
      final inputs = calloc<ffi.Pointer<bg.OrtValue>>(1)..[0] = value;
      try {
        _check(api.Run.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSession>, ffi.Pointer<bg.OrtRunOptions>, ffi.Pointer<ffi.Pointer<ffi.Char>>,
                ffi.Pointer<ffi.Pointer<bg.OrtValue>>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>, int,
                ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
            _session, ffi.nullptr, inNames, inputs, 1, outNames, _outputNames.length, outputs));
      } finally {
        calloc.free(inputs);
        _release(value);
      }
      return [for (var i = 0; i < _outputNames.length; i++) _read(outputs[i])];
    } finally {
      calloc.free(dims);
      calloc.free(valueOut);
      calloc.free(inNames);
      calloc.free(outNames);
      calloc.free(outputs);
    }
  }

  /// Copies an output tensor out in one go, then frees it.
  static Float32List _read(ffi.Pointer<bg.OrtValue> value) {
    final api = _api.ref;
    final info = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    final count = calloc<ffi.Size>();
    final data = calloc<ffi.Pointer<ffi.Void>>();
    try {
      _check(api.GetTensorTypeAndShape.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(value, info));
      _check(api.GetTensorShapeElementCount
          .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Size>)>()(
          info.value, count));
      api.ReleaseTensorTypeAndShapeInfo
          .asFunction<void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)>()(info.value);
      _check(api.GetTensorMutableData
          .asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(value, data));
      return Float32List.fromList(data.value.cast<ffi.Float>().asTypedList(count.value));
    } finally {
      calloc.free(info);
      calloc.free(count);
      calloc.free(data);
      _release(value);
    }
  }

  static void _release(ffi.Pointer<bg.OrtValue> value) {
    if (value == ffi.nullptr) return;
    _api.ref.ReleaseValue.asFunction<void Function(ffi.Pointer<bg.OrtValue>)>()(value);
  }

  void close() {
    final api = _api.ref;
    api.ReleaseSession.asFunction<void Function(ffi.Pointer<bg.OrtSession>)>()(_session);
    api.ReleaseSessionOptions.asFunction<void Function(ffi.Pointer<bg.OrtSessionOptions>)>()(_options);
    api.ReleaseMemoryInfo.asFunction<void Function(ffi.Pointer<bg.OrtMemoryInfo>)>()(_memory);
    for (final n in [..._inputNames, ..._outputNames]) {
      malloc.free(n);
    }
    if (_inCapacity > 0) malloc.free(_in);
  }

  /// Throws the runtime's message if [status] is an error.
  static void _check(Object status) {
    final ptr = status is int ? ffi.Pointer<bg.OrtStatus>.fromAddress(status) : status as bg.OrtStatusPtr;
    if (ptr == ffi.nullptr) return;
    final api = _api.ref;
    final message = api.GetErrorMessage.asFunction<ffi.Pointer<ffi.Char> Function(bg.OrtStatusPtr)>()(ptr)
        .cast<Utf8>()
        .toDartString();
    api.ReleaseStatus.asFunction<void Function(bg.OrtStatusPtr)>()(ptr);
    throw StateError('ONNX Runtime: $message');
  }
}
