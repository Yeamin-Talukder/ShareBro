import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Small male/female classifier (MIT, github.com/shubham0204/
/// Age-Gender_Estimation_TF-Android): a 128x128 RGB face in, the chances of
/// male and female out.
const _modelAsset = 'assets/models/gender_lite.tflite';
const _size = 128;

/// Guesses each person's gender from a few of their clearest face crops,
/// averaged so one odd photo doesn't decide it. Returns the chance (0..1)
/// that each person is female. Runs off the main isolate.
Future<Map<int, double>> guessFemaleChance(Map<int, List<Uint8List>> facesByPerson) async {
  if (facesByPerson.isEmpty) return const {};
  final model = (await rootBundle.load(_modelAsset)).buffer.asUint8List();
  return Isolate.run(() => _guess(model, facesByPerson));
}

Map<int, double> _guess(Uint8List model, Map<int, List<Uint8List>> facesByPerson) {
  final interpreter = Interpreter.fromBuffer(model);
  try {
    final out = <int, double>{};
    for (final MapEntry(key: person, value: faces) in facesByPerson.entries) {
      var sum = 0.0, n = 0;
      for (final jpeg in faces) {
        final face = img.decodeJpg(jpeg);
        if (face == null) continue;
        final small = img.copyResize(face, width: _size, height: _size, interpolation: img.Interpolation.linear);
        final input = Float32List(_size * _size * 3);
        var i = 0;
        for (final p in small) {
          input[i++] = p.r / 255;
          input[i++] = p.g / 255;
          input[i++] = p.b / 255;
        }
        final result = [List.filled(2, 0.0)];
        interpreter.run(input.buffer.asUint8List(), result);
        final (male, female) = (result[0][0], result[0][1]);
        if (male + female <= 0) continue;
        sum += female / (male + female);
        n++;
      }
      if (n > 0) out[person] = sum / n;
    }
    return out;
  } finally {
    interpreter.close();
  }
}
