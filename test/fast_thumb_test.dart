import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/ui/fast_thumb.dart';

void main() {
  test('sizes snap to a few shared steps', () {
    expect(FastThumb.step(100), 128);
    expect(FastThumb.step(300), 384);
    expect(FastThumb.step(384), 384);
    expect(FastThumb.step(1500), 1600);
    expect(FastThumb.step(9000), 2400);
  });

  test('the same photo at the same size is one cache entry', () {
    expect(const FastThumb('42', 384, cover: true), const FastThumb('42', 384, cover: true));
    expect(const FastThumb('42', 384, cover: true).hashCode, const FastThumb('42', 384, cover: true).hashCode);
    expect(const FastThumb('42', 384) == const FastThumb('42', 384, cover: true), isFalse);
    expect(const FastThumb('42', 384) == const FastThumb('43', 384), isFalse);
  });
}
