import 'dart:convert';
import 'dart:typed_data';

/// CRC-32 (the checksum ZIP uses), computed incrementally.
class Crc32 {
  static final Uint32List _table = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }();

  int _crc = 0xFFFFFFFF;

  void add(List<int> data) {
    var c = _crc;
    for (final b in data) {
      c = _table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    _crc = c;
  }

  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Keep each ZIP well under the 4 GB limit of plain (non-ZIP64) archives.
const zipPartLimit = 3500 * 1024 * 1024;

class ZipEntry {
  ZipEntry(this.name, this.size, this.modified, this.open);

  final String name;
  final int size;
  final DateTime modified;
  final Stream<List<int>> Function() open;
}

/// Writes a ZIP with no compression (photos are already compressed) as a
/// stream, one file after another, so nothing big is held in memory.
Stream<List<int>> zipStream(List<ZipEntry> entries) async* {
  var offset = 0;
  final central = BytesBuilder();
  for (final e in entries) {
    final name = utf8.encode(e.name);
    final (time, date) = _dosTime(e.modified);
    // Bit 3: sizes and CRC follow the data; bit 11: UTF-8 names.
    const flags = 0x0808;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, 0, Endian.little)
      ..setUint16(10, time, Endian.little)
      ..setUint16(12, date, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    final header = [...local.buffer.asUint8List(), ...name];
    yield header;
    final start = offset;
    offset += header.length;

    final crc = Crc32();
    var size = 0;
    await for (final chunk in e.open()) {
      crc.add(chunk);
      size += chunk.length;
      yield chunk;
    }
    offset += size;
    final descriptor = ByteData(16)
      ..setUint32(0, 0x08074b50, Endian.little)
      ..setUint32(4, crc.value, Endian.little)
      ..setUint32(8, size, Endian.little)
      ..setUint32(12, size, Endian.little);
    yield descriptor.buffer.asUint8List();
    offset += 16;

    final c = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, flags, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, time, Endian.little)
      ..setUint16(14, date, Endian.little)
      ..setUint32(16, crc.value, Endian.little)
      ..setUint32(20, size, Endian.little)
      ..setUint32(24, size, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, start, Endian.little);
    central
      ..add(c.buffer.asUint8List())
      ..add(name);
  }
  final dir = central.toBytes();
  yield dir;
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, dir.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  yield end.buffer.asUint8List();
}

/// Size of the finished ZIP, so browsers can show download progress.
int zipLength(List<ZipEntry> entries) {
  var n = 22;
  for (final e in entries) {
    final name = utf8.encode(e.name).length;
    n += 30 + name + e.size + 16 + 46 + name;
  }
  return n;
}

(int, int) _dosTime(DateTime t) {
  final d = t.year < 1980 ? DateTime(1980) : t;
  return (
    (d.hour << 11) | (d.minute << 5) | (d.second ~/ 2),
    ((d.year - 1980) << 9) | (d.month << 5) | d.day,
  );
}

/// Splits files into ZIP parts that each stay under [zipPartLimit].
List<List<T>> zipParts<T>(List<T> files, int Function(T) sizeOf) {
  final parts = <List<T>>[[]];
  var size = 0;
  for (final f in files) {
    if (size + sizeOf(f) > zipPartLimit && parts.last.isNotEmpty) {
      parts.add([]);
      size = 0;
    }
    parts.last.add(f);
    size += sizeOf(f);
  }
  return parts;
}
