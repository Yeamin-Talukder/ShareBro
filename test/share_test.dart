import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_organizer/share/prepare.dart';
import 'package:photo_organizer/share/protocol.dart';
import 'package:photo_organizer/share/zip_stream.dart';

void main() {
  test('CRC-32 matches the standard check value', () {
    final crc = Crc32()..add(utf8.encode('123456789'));
    expect(crc.value, 0xCBF43926);
  });

  test('streamed ZIP has the length we promised and valid signatures', () async {
    final a = utf8.encode('hello');
    final b = List<int>.generate(1000, (i) => i % 251);
    final entries = [
      ZipEntry('a.txt', a.length, DateTime(2026, 10, 1), () => Stream.value(a)),
      ZipEntry('photos/b.jpg', b.length, DateTime(2026, 10, 2), () => Stream.value(b)),
    ];
    final bytes = <int>[];
    await for (final chunk in zipStream(entries)) {
      bytes.addAll(chunk);
    }
    expect(bytes.length, zipLength(entries));
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    expect(data.getUint32(0, Endian.little), 0x04034b50); // first local header
    final end = bytes.length - 22;
    expect(data.getUint32(end, Endian.little), 0x06054b50); // end of central directory
    expect(data.getUint16(end + 10, Endian.little), 2); // two entries
  });

  test('ZIP parts stay under the limit', () {
    final sizes = [zipPartLimit ~/ 2, zipPartLimit ~/ 2, zipPartLimit ~/ 2];
    final parts = zipParts(sizes, (s) => s);
    expect(parts.length, 2);
  });

  test('JPEG metadata is stripped without touching image data', () {
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8, // start
      0xFF, 0xE1, 0x00, 0x0A, ...ascii('Exif'), 0, 0, 1, 2, // EXIF (GPS lives here)
      0xFF, 0xDB, 0x00, 0x04, 9, 9, // quantization table: kept
      0xFF, 0xDA, 0x00, 0x02, 7, 7, 7, 0xFF, 0xD9, // scan data to the end
    ]);
    final out = stripJpegMetadata(jpeg);
    expect(out, [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 9, 9, 0xFF, 0xDA, 0x00, 0x02, 7, 7, 7, 0xFF, 0xD9]);
  });

  test('EXIF orientation is read from the first IFD', () {
    // Little-endian TIFF with one entry: orientation (0x0112) = 6.
    final tiff = [
      0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // header, IFD at 8
      0x01, 0x00, // one entry
      0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
    ];
    final app1 = [...ascii('Exif'), 0, 0, ...tiff];
    final jpeg = Uint8List.fromList([
      0xFF, 0xD8,
      0xFF, 0xE1, (app1.length + 2) >> 8, (app1.length + 2) & 0xFF, ...app1,
      0xFF, 0xDA, 0x00, 0x02,
    ]);
    expect(exifOrientation(jpeg), 6);
  });

  test('LocalSend info round-trips and unknown device types become desktop', () {
    final info = LsInfo(alias: 'Camera', fingerprint: 'abc', protocol: 'http', download: true);
    final json = info.toJson(announce: true);
    expect(json['announce'], true);
    expect(json['version'], lsVersion);
    final back = LsInfo.fromJson({...json, 'deviceType': 'toaster'});
    expect(back.alias, 'Camera');
    expect(back.deviceType, LsDeviceType.desktop);
    expect(info.toJson().containsKey('announce'), isFalse);
  });

  test('file entries carry LocalSend fields', () {
    final f = LsFile(id: 'p0', fileName: 'IMG_1.jpg', size: 10, fileType: mimeFor('IMG_1.jpg'),
        modified: DateTime.utc(2026, 1, 1)).toJson();
    expect(f['fileType'], 'image/jpeg');
    expect((f['metadata'] as Map)['modified'], '2026-01-01T00:00:00.000Z');
  });
}

List<int> ascii(String s) => s.codeUnits;
