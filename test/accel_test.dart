import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/accel.dart';

void main() {
  test('the CPU is used until another chip is measured and clearly faster', () {
    final s = AccelState('k');
    expect(s.best, Accel.cpu);
    s.ms[Accel.cpu] = 10;
    expect(s.best, Accel.cpu);
    // 5% quicker isn't worth a chip's start-up time.
    s.ms[Accel.gpu] = 9.5;
    expect(s.best, Accel.cpu);
    s.ms[Accel.gpu] = 6;
    expect(s.best, Accel.gpu);
    s.ms[Accel.npu] = 3;
    expect(s.best, Accel.npu);
  });

  test('a chip that failed is never picked, whatever its time', () {
    final s = AccelState('k', ms: {Accel.cpu: 10, Accel.gpu: 6, Accel.npu: 2}, bad: {Accel.npu});
    expect(s.best, Accel.gpu);
    s.bad.add(Accel.gpu);
    expect(s.best, Accel.cpu);
  });

  test('a try that never finished marks the chip as crashed', () {
    final s = AccelState('k', ms: {Accel.cpu: 10}, trying: Accel.npu);
    expect(s.settleCrash(), isTrue);
    expect(s.bad, {Accel.npu});
    expect(s.trying, isNull);
    expect(s.settleCrash(), isFalse);
    // Asking for it by name in Settings gives it another go.
    s.forget(Accel.npu);
    expect(s.tried(Accel.npu), isFalse);
  });

  test('what was learned survives a restart, but not a system update', () {
    final dir = Directory.systemTemp.createTempSync('accel_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/chips.json';
    AccelState('model|android|15', ms: {Accel.cpu: 11.5, Accel.gpu: 4.25}, bad: {Accel.npu}, trying: Accel.gpu)
        .write(path);

    final back = AccelState.read(path, 'model|android|15');
    expect(back.ms, {Accel.cpu: 11.5, Accel.gpu: 4.25});
    expect(back.bad, {Accel.npu});
    expect(back.trying, Accel.gpu);

    final updated = AccelState.read(path, 'model|android|16');
    expect(updated.ms, isEmpty);
    expect(updated.bad, isEmpty);
    expect(updated.trying, isNull);
  });

  test('a missing or damaged file starts afresh', () {
    final dir = Directory.systemTemp.createTempSync('accel_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/chips.json';
    expect(AccelState.read(path, 'k').ms, isEmpty);
    File(path).writeAsStringSync('{"key": "k", "ms": {"warp": 1, "gpu": "fast"}, "bad": [7, "npu"]');
    expect(AccelState.read(path, 'k').tried(Accel.npu), isFalse);
    File(path).writeAsStringSync(jsonEncode({
      'key': 'k',
      'ms': {'warp': 1, 'gpu': 'fast', 'cpu': 9},
      'bad': [7, 'npu'],
      'trying': 'toaster',
    }));
    final s = AccelState.read(path, 'k');
    expect(s.ms, {Accel.cpu: 9.0});
    expect(s.bad, {Accel.npu});
    expect(s.trying, isNull);
  });

  test('settings choices map to chips', () {
    expect(AccelChoice.byName(null), AccelChoice.auto);
    expect(AccelChoice.byName('nonsense'), AccelChoice.auto);
    expect(AccelChoice.byName('gpu').only, Accel.gpu);
    expect(AccelChoice.auto.only, isNull);
  });
}
