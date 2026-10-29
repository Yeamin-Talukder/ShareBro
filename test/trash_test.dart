import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/data/trash.dart';

void main() {
  test('trash items are read from Android and count down their days', () {
    final soon = DateTime.now().add(const Duration(days: 2, hours: 3));
    final item = TrashItem.fromMap({
      'id': 42,
      'name': 'IMG_1.jpg',
      'mime': 'image/jpeg',
      'size': 1234,
      'video': false,
      'expires': soon.millisecondsSinceEpoch,
      'duration': 0,
    });
    expect(item.id, 42);
    expect(item.isVideo, isFalse);
    expect(item.daysLeft, 3);

    final gone = TrashItem.fromMap({'id': 1, 'expires': DateTime.now().millisecondsSinceEpoch - 1000});
    expect(gone.daysLeft, 0);
    expect(gone.name, 'Item');
  });
}
