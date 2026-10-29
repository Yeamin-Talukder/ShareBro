import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_organizer/share/prepare.dart';
import 'package:photo_organizer/share/protocol.dart';
import 'package:photo_organizer/share/receive.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('send_items'));
  tearDown(() async => tmp.delete(recursive: true));

  test('files, folders and messages become prepared files', () async {
    final trip = Directory(p.join(tmp.path, 'Trip'));
    await Directory(p.join(trip.path, 'day1')).create(recursive: true);
    await File(p.join(trip.path, 'plan.pdf')).writeAsString('pdf');
    await File(p.join(trip.path, 'day1', 'notes.txt')).writeAsString('hello');
    final loose = File(p.join(tmp.path, 'plan.pdf'))..writeAsStringSync('other');

    final folder = await SendItem.folder(trip.path);
    expect(folder.map((i) => i.name).toSet(), {'Trip/plan.pdf', 'Trip/day1/notes.txt'});

    final out = Directory(p.join(tmp.path, 'out'))..createSync();
    final files = await prepareItems(
      [...folder, SendItem.file(loose.path), const SendItem.text('Meet at 7')],
      SendQuality.original,
      out,
    );
    expect(files, hasLength(4));
    expect(files.where((f) => f.isAsset), isEmpty);
    expect(files.firstWhere((f) => f.fileName == 'plan.pdf').mime, 'application/pdf');
    final msg = files.firstWhere((f) => f.mime == 'text/plain' && f.preview != null);
    expect(msg.preview, 'Meet at 7');
    expect(await msg.file.readAsString(), 'Meet at 7');
  });

  test('same names are kept apart', () async {
    final a = File(p.join(tmp.path, 'a', 'x.txt'))..createSync(recursive: true);
    final b = File(p.join(tmp.path, 'b', 'x.txt'))..createSync(recursive: true);
    final files = await prepareItems([SendItem.file(a.path), SendItem.file(b.path)], SendQuality.original, tmp);
    expect(files.map((f) => f.fileName), ['x.txt', 'x (2).txt']);
  });

  test('incoming requests describe themselves', () {
    IncomingFile f(String name, {String? text}) => IncomingFile(name, name, 3, mimeFor(name), preview: text);
    expect(IncomingRequest('Maya', [f('a.jpg'), f('b.jpg')], 'Wi-Fi').summary, '2 photos');
    expect(IncomingRequest('Maya', [f('a.jpg'), f('b.pdf')], 'Wi-Fi').summary, '2 files');
    expect(IncomingRequest('Maya', [f('m.txt', text: 'hi')], 'Wi-Fi').summary, 'a message');
    expect(mimeFor('clip.MP4'), 'video/mp4');
  });
}
