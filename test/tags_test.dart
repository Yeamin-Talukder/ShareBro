import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/face/tags.dart';

PhotoFacts _facts({
  int faces = 0,
  double maxArea = 0,
  double? sharpness,
  int width = 3000,
  int height = 4000,
  String folder = 'DCIM/Camera/',
  String title = 'PXL_20261012.jpg',
  bool location = false,
  List<String> labels = const [],
}) =>
    PhotoFacts(
      faceCount: faces,
      maxFaceArea: maxArea,
      minFaceSharpness: sharpness,
      width: width,
      height: height,
      folder: folder,
      title: title,
      hasLocation: location,
      labels: labels,
    );

void main() {
  test('close-up face with one person is a solo selfie', () {
    final t = tagsFor(_facts(faces: 1, maxArea: 0.12, sharpness: 200));
    expect(t, containsAll(['solo', 'selfie', 'portrait']));
    expect(t, isNot(contains('blurry')));
  });

  test('big group with small faces is a group, not a selfie', () {
    final t = tagsFor(_facts(faces: 8, maxArea: 0.01, width: 4000, height: 3000));
    expect(t, containsAll(['group', 'landscape']));
    expect(t, isNot(contains('selfie')));
  });

  test('scenery gets labels and no_people', () {
    final t = tagsFor(_facts(labels: ['Beach', 'Sky'], location: true));
    expect(t, containsAll(['no_people', 'label:Beach', 'label:Sky', 'location']));
  });

  test('screenshots skip people and scene tags', () {
    final t = tagsFor(_facts(
        folder: 'Pictures/Screenshots/', title: 'Screenshot_1.png', labels: ['Text']));
    expect(t, contains('screenshot'));
    expect(t, isNot(contains('no_people')));
    expect(t, isNot(contains('label:Text')));
  });

  test('WhatsApp folder and blurry faces are tagged', () {
    final t = tagsFor(_facts(
        faces: 2, maxArea: 0.02, sharpness: 30, folder: 'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/'));
    expect(t, containsAll(['couple', 'whatsapp', 'blurry']));
  });

  test('Telegram photos are Telegram, not Downloads', () {
    final t = tagsFor(_facts(folder: 'Download/Telegram/Telegram Images/'));
    expect(t, contains('telegram'));
    expect(t, isNot(contains('download')));
    expect(tagsFor(_facts(folder: 'Download/')), contains('download'));
  });
}
