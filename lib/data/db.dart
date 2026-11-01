import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Faces narrower than this share of the photo are too small for ML Kit's
/// eye-open, smile and head-turn readings to be trusted.
const eyeReadableWidth = 0.08;

/// A detected face. The photo itself is only referenced by [assetId];
/// nothing is ever copied out of the photo library.
class FaceRecord {
  FaceRecord({
    required this.id,
    required this.assetId,
    required this.embedding,
    required this.personId,
    required this.locked,
  });

  final int id;
  final String assetId;
  final Float32List embedding;
  final int? personId;

  /// True once the user has confirmed or rejected this face by hand, so
  /// automatic grouping never moves it again.
  final bool locked;
}

enum Gender {
  male('m', 'Male'),
  female('f', 'Female');

  const Gender(this.code, this.label);

  /// How it's stored.
  final String code;
  final String label;

  static Gender? fromCode(String? code) => values.where((g) => g.code == code).firstOrNull;
}

class PersonSummary {
  PersonSummary({
    required this.id,
    required this.name,
    required this.photoCount,
    required this.coverThumb,
    this.nickname,
    this.gender,
    this.genderGuessed = false,
  });

  final int id;
  final String? name;
  final int photoCount;
  final Uint8List? coverThumb;
  final String? nickname;

  /// Set by hand, or else the app's guess when it's fairly sure; null when
  /// neither.
  final Gender? gender;

  /// [gender] is the app's guess, not set by hand.
  final bool genderGuessed;

  String get displayName => name ?? 'Unnamed #$id';
}

class TripSummary {
  TripSummary(this.id, this.name, this.photoCount, this.albumId);

  final int id;
  final String name;
  final int photoCount;

  /// Phone album id, plus `@from-to` for a date-limited scan.
  final String albumId;
}

/// A saved set of people, e.g. "Family" or "Office friends".
class PersonGroup {
  PersonGroup(this.id, this.name, this.members);

  final int id;
  final String name;
  final Set<int> members;
}

/// One face in a group photo, for picking a burst's best shot. Eye and
/// smile readings are null when the face is too small to read.
class ShotFace {
  ShotFace(this.width, this.eyesOpen, this.smile, this.sharpness);

  final double width;
  final double? eyesOpen, smile, sharpness;
}

/// A photo with two or more faces.
class GroupShot {
  GroupShot(this.assetId, this.takenAt, this.faces);

  final String assetId;

  /// Milliseconds since epoch.
  final int takenAt;
  final List<ShotFace> faces;
}

/// What the duplicate finder needs to know about each photo.
class PhotoFingerprint {
  PhotoFingerprint(this.assetId, this.hash, this.takenAt, this.quality, this.hidden);

  final String assetId;
  final int hash;
  final int takenAt;
  final double quality;
  final bool hidden;
}

class FaceThumb {
  FaceThumb(this.id, this.assetId, this.thumb);

  final int id;
  final String assetId;
  final Uint8List thumb;
}

/// One photo of a person, with where their face is and how good it looks.
class PersonPhoto {
  PersonPhoto({
    required this.assetId,
    required this.face,
    required this.sharpness,
    required this.faceCount,
    required this.takenAt,
    this.eyesOpen,
    this.smile,
  });

  final String assetId;

  /// 0..1 chance this person's eyes are open / they're smiling (null for
  /// faces scanned before these were recorded).
  final double? eyesOpen;
  final double? smile;

  /// When the photo was taken; null until the date has been read.
  final DateTime? takenAt;

  /// Normalized 0..1 box of this person's face in the photo.
  final Rect face;

  /// Edge detail of the face crop; null for faces scanned before it existed.
  final double? sharpness;
  final int faceCount;

  /// Bigger, sharper, eyes-open, smiling faces score higher ("best first").
  double get quality =>
      face.width *
      (sharpness ?? 80).clamp(0, 400) *
      (eyesOpen ?? 0.8).clamp(0.15, 1) *
      (0.7 + 0.3 * (smile ?? 0.5));
}

/// A face that isn't in any person yet, offered for review.
class UnsortedFace {
  UnsortedFace(this.id, this.embedding, this.thumb);

  final int id;
  final Float32List embedding;
  final Uint8List thumb;
}

class NewFace {
  NewFace({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.embedding,
    required this.thumb,
    required this.sharpness,
    this.eyesOpen,
    this.smile,
    this.yaw,
  });

  // Normalized 0..1 relative to the photo, so they survive any thumbnail size.
  final double left, top, width, height;
  final Float32List embedding;
  final Uint8List thumb;
  final double sharpness;

  /// From ML Kit: the lower of the two eye-open chances, smile chance, and
  /// how far the head is turned (degrees).
  final double? eyesOpen, smile, yaw;
}

/// A LocalSend device seen before, and whose phone it is.
class SavedDevice {
  SavedDevice({
    required this.fingerprint,
    required this.alias,
    this.model,
    this.type,
    this.ip,
    this.port,
    this.protocol,
    this.lastSeen,
    this.personId,
  });

  factory SavedDevice.fromRow(Map<String, Object?> r) => SavedDevice(
        fingerprint: r['fingerprint'] as String,
        alias: r['alias'] as String,
        model: r['device_model'] as String?,
        type: r['device_type'] as String?,
        ip: r['ip'] as String?,
        port: r['port'] as int?,
        protocol: r['protocol'] as String?,
        lastSeen: r['last_seen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_seen'] as int),
        personId: r['person_id'] as int?,
      )..favorite = r['favorite'] == 1;

  final String fingerprint;
  final String alias;
  final String? model, type, ip, protocol;
  final int? port;
  final DateTime? lastSeen;
  final int? personId;
  bool favorite = false;
}

/// One file (or text message) sent or received.
class Transfer {
  Transfer({
    this.id,
    required this.incoming,
    required this.peer,
    required this.fileName,
    required this.size,
    this.mime,
    this.location,
    this.text,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final int? id;
  final bool incoming;

  /// The other device's name.
  final String peer;
  final String fileName;
  final int size;
  final String? mime;

  /// Where a received file was saved (content:// URI or path).
  final String? location;

  /// The message, for text transfers.
  final String? text;
  final DateTime at;

  bool get isText => text != null;
  bool get isMedia => (mime ?? '').startsWith('image/') || (mime ?? '').startsWith('video/');
}

/// Inclusive range of whole days; [end] covers until the end of that day.
class DaySpan {
  DaySpan(DateTime start, DateTime end)
      : start = DateTime(start.year, start.month, start.day),
        end = DateTime(end.year, end.month, end.day, 23, 59, 59, 999);

  final DateTime start, end;

  bool contains(DateTime t) => !t.isBefore(start) && !t.isAfter(end);

  @override
  bool operator ==(Object other) =>
      other is DaySpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// A person who appears in one particular photo.
class PhotoPerson {
  PhotoPerson(this.id, this.name, this.thumb);

  final int id;
  final String? name;
  final Uint8List thumb;

  String get displayName => name ?? 'Unnamed #$id';
}

/// Who a set of faces belonged to before an edit, so it can be undone.
class FaceSnapshot {
  FaceSnapshot(this.rows);

  final List<({int id, int? personId, bool locked})> rows;
}

class AppDb {
  AppDb._(this._db);

  final Database _db;

  /// Bumped whenever a transfer is added to or removed from the history.
  final transfersChanged = ValueNotifier<int>(0);

  static Future<AppDb> open() async {
    final path = p.join(await getDatabasesPath(), 'photo_organizer.db');
    final db = await openDatabase(
      path,
      version: 8,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE photos (
            asset_id TEXT PRIMARY KEY,
            scanned_at INTEGER NOT NULL,
            face_count INTEGER NOT NULL,
            taken_at INTEGER,
            tag_version INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE persons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            created_at INTEGER NOT NULL
          )''');
        await db.execute('''
          CREATE TABLE faces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL REFERENCES photos(asset_id) ON DELETE CASCADE,
            left REAL NOT NULL,
            top REAL NOT NULL,
            width REAL NOT NULL,
            height REAL NOT NULL,
            embedding BLOB NOT NULL,
            thumb BLOB NOT NULL,
            person_id INTEGER REFERENCES persons(id) ON DELETE SET NULL,
            locked INTEGER NOT NULL DEFAULT 0,
            sharpness REAL,
            reviewed INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('CREATE INDEX faces_person ON faces(person_id)');
        await db.execute('CREATE INDEX faces_asset ON faces(asset_id)');
        await _createV2Tables(db);
        await _createTagsTable(db);
        await _upgradeTo5(db);
        await _upgradeTo6(db);
        await _upgradeTo7(db);
        await _upgradeTo8(db);
      },
      onUpgrade: (db, from, _) async {
        if (from < 2) {
          await db.execute('ALTER TABLE faces ADD COLUMN sharpness REAL');
          await db.execute(
              'ALTER TABLE faces ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0');
          await _createV2Tables(db);
        }
        if (from < 3) {
          // Filled in by [ScanController.backfillDates].
          await db.execute('ALTER TABLE photos ADD COLUMN taken_at INTEGER');
        }
        if (from < 4) {
          // Photos get categorised the next time their album is scanned.
          await db.execute(
              'ALTER TABLE photos ADD COLUMN tag_version INTEGER NOT NULL DEFAULT 0');
          await _createTagsTable(db);
        }
        if (from < 5) await _upgradeTo5(db);
        if (from < 6) await _upgradeTo6(db);
        if (from < 7) await _upgradeTo7(db);
        if (from < 8) await _upgradeTo8(db);
      },
    );
    return AppDb._(db);
  }

  static Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE trips (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        album_id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''');
    await db.execute('''
      CREATE TABLE trip_photos (
        trip_id INTEGER NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL,
        PRIMARY KEY (trip_id, asset_id)
      )''');
    await db.execute('CREATE INDEX trip_photos_asset ON trip_photos(asset_id)');
    await db.execute(
        'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  static Future<void> _createTagsTable(Database db) async {
    await db.execute('''
      CREATE TABLE photo_tags (
        asset_id TEXT NOT NULL REFERENCES photos(asset_id) ON DELETE CASCADE,
        tag TEXT NOT NULL,
        PRIMARY KEY (asset_id, tag)
      )''');
    await db.execute('CREATE INDEX photo_tags_tag ON photo_tags(tag)');
  }

  /// Eyes/smiles, duplicate fingerprints, location, quality, groups, ignore
  /// list, nicknames and dismissed merge suggestions.
  static Future<void> _upgradeTo5(Database db) async {
    for (final sql in [
      'ALTER TABLE faces ADD COLUMN eyes_open REAL',
      'ALTER TABLE faces ADD COLUMN smile REAL',
      'ALTER TABLE faces ADD COLUMN yaw REAL',
      'ALTER TABLE photos ADD COLUMN dhash INTEGER',
      'ALTER TABLE photos ADD COLUMN lat REAL',
      'ALTER TABLE photos ADD COLUMN lng REAL',
      'ALTER TABLE photos ADD COLUMN bytes INTEGER',
      'ALTER TABLE photos ADD COLUMN quality REAL',
      'ALTER TABLE photos ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE persons ADD COLUMN nickname TEXT',
      'ALTER TABLE persons ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE persons ADD COLUMN cover_face_id INTEGER',
      '''CREATE TABLE person_groups (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           name TEXT NOT NULL)''',
      '''CREATE TABLE person_group_members (
           group_id INTEGER NOT NULL REFERENCES person_groups(id) ON DELETE CASCADE,
           person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
           PRIMARY KEY (group_id, person_id))''',
      '''CREATE TABLE dismissed_pairs (
           a INTEGER NOT NULL, b INTEGER NOT NULL, PRIMARY KEY (a, b))''',
    ]) {
      await db.execute(sql);
    }
  }

  /// Sharing: known devices (paired to people) and what was sent to whom.
  static Future<void> _upgradeTo6(Database db) async {
    await db.execute('''
      CREATE TABLE devices (
        fingerprint TEXT PRIMARY KEY,
        alias TEXT NOT NULL,
        device_model TEXT,
        device_type TEXT,
        ip TEXT,
        port INTEGER,
        protocol TEXT,
        last_seen INTEGER,
        person_id INTEGER REFERENCES persons(id) ON DELETE SET NULL
      )''');
    await db.execute('''
      CREATE TABLE sent (
        asset_id TEXT NOT NULL,
        person_id INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
        fingerprint TEXT,
        sent_at INTEGER NOT NULL,
        PRIMARY KEY (asset_id, person_id)
      )''');
    await db.execute('CREATE INDEX sent_person ON sent(person_id)');
  }

  /// Transfer history (LocalSend-style) and favourite devices.
  static Future<void> _upgradeTo7(Database db) async {
    await db.execute('''
      CREATE TABLE transfers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        incoming INTEGER NOT NULL,
        peer TEXT NOT NULL,
        file_name TEXT NOT NULL,
        size INTEGER NOT NULL,
        mime TEXT,
        location TEXT,
        text TEXT,
        at INTEGER NOT NULL
      )''');
    await db.execute('ALTER TABLE devices ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0');
  }

  /// Gender: set by hand, and the app's guess (chance of female, 0..1).
  static Future<void> _upgradeTo8(Database db) async {
    await db.execute('ALTER TABLE persons ADD COLUMN gender TEXT');
    await db.execute('ALTER TABLE persons ADD COLUMN gender_guess REAL');
  }

  // ---- Transfer history ----

  Future<void> addTransfer(Transfer t) async {
    await _db.insert('transfers', {
        'incoming': t.incoming ? 1 : 0,
        'peer': t.peer,
        'file_name': t.fileName,
        'size': t.size,
        'mime': t.mime,
        'location': t.location,
        'text': t.text,
        'at': t.at.millisecondsSinceEpoch,
      });
    transfersChanged.value++;
  }

  Future<List<Transfer>> transfers({int limit = 300}) async {
    final rows = await _db.query('transfers', orderBy: 'at DESC', limit: limit);
    return [
      for (final r in rows)
        Transfer(
          id: r['id'] as int,
          incoming: r['incoming'] == 1,
          peer: r['peer'] as String,
          fileName: r['file_name'] as String,
          size: r['size'] as int,
          mime: r['mime'] as String?,
          location: r['location'] as String?,
          text: r['text'] as String?,
          at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
        ),
    ];
  }

  Future<void> deleteTransfer(int id) async {
    await _db.delete('transfers', where: 'id = ?', whereArgs: [id]);
    transfersChanged.value++;
  }

  Future<void> clearTransfers() async {
    await _db.delete('transfers');
    transfersChanged.value++;
  }

  Future<void> setFavoriteDevice(String fingerprint, bool favorite) => _db.update(
      'devices', {'favorite': favorite ? 1 : 0}, where: 'fingerprint = ?', whereArgs: [fingerprint]);

  // ---- Sharing ----

  Future<void> saveDevice(
      {required String fingerprint,
      required String alias,
      String? model,
      String? type,
      required String ip,
      required int port,
      required String protocol}) async {
    final row = {
      'alias': alias,
      'device_model': model,
      'device_type': type,
      'ip': ip,
      'port': port,
      'protocol': protocol,
      'last_seen': DateTime.now().millisecondsSinceEpoch,
    };
    final n = await _db.update('devices', row, where: 'fingerprint = ?', whereArgs: [fingerprint]);
    if (n == 0) await _db.insert('devices', {'fingerprint': fingerprint, ...row});
  }

  /// "This is Rahim's phone." A device belongs to at most one person.
  Future<void> pairDevice(String fingerprint, int? personId) => _db.update(
      'devices', {'person_id': personId}, where: 'fingerprint = ?', whereArgs: [fingerprint]);

  Future<List<SavedDevice>> savedDevices({int? personId}) async {
    final rows = await _db.query('devices',
        where: personId == null ? null : 'person_id = ?',
        whereArgs: personId == null ? null : [personId],
        orderBy: 'last_seen DESC');
    return [for (final r in rows) SavedDevice.fromRow(r)];
  }

  Future<void> forgetDevice(String fingerprint) =>
      _db.delete('devices', where: 'fingerprint = ?', whereArgs: [fingerprint]);

  Future<void> markSent(int personId, Iterable<String> assetIds, String? fingerprint) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final id in assetIds) {
      batch.insert('sent', {
        'asset_id': id,
        'person_id': personId,
        'fingerprint': fingerprint,
        'sent_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<Set<String>> sentTo(int personId) async {
    final rows = await _db.query('sent',
        columns: ['asset_id'], where: 'person_id = ?', whereArgs: [personId]);
    return {for (final r in rows) r['asset_id'] as String};
  }

  Future<void> clearSent(int personId) =>
      _db.delete('sent', where: 'person_id = ?', whereArgs: [personId]);

  // ---- Settings ----

  Future<String?> setting(String key) async {
    final rows = await _db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) => _db.insert(
      'settings', {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace);

  // ---- Trips ----

  /// One trip per album; scanning the same album again reuses it.
  Future<int> tripForAlbum(String albumId, String name) async {
    final rows = await _db.query('trips',
        columns: ['id'], where: 'album_id = ?', whereArgs: [albumId]);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return _db.insert('trips', {
      'album_id': albumId,
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> addToTrip(int tripId, Iterable<String> assetIds) async {
    final batch = _db.batch();
    for (final id in assetIds) {
      batch.insert('trip_photos', {'trip_id': tripId, 'asset_id': id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<List<TripSummary>> trips() async {
    final rows = await _db.rawQuery('''
      SELECT t.id, t.name, t.album_id, COUNT(tp.asset_id) AS n
      FROM trips t LEFT JOIN trip_photos tp ON tp.trip_id = t.id
      GROUP BY t.id ORDER BY t.created_at DESC''');
    return [
      for (final r in rows)
        TripSummary(r['id'] as int, r['name'] as String, r['n'] as int,
            r['album_id'] as String),
    ];
  }

  Future<void> renameTrip(int id, String name) =>
      _db.update('trips', {'name': name.trim()},
          where: 'id = ?', whereArgs: [id]);

  /// Forgets the trip only; its photos and faces stay.
  Future<void> deleteTrip(int id) =>
      _db.delete('trips', where: 'id = ?', whereArgs: [id]);

  // ---- Scanning ----

  Future<Set<String>> scannedAssetIds() async {
    final rows = await _db.query('photos', columns: ['asset_id']);
    return {for (final r in rows) r['asset_id'] as String};
  }

  Future<void> savePhoto(String assetId, List<NewFace> faces,
      {required DateTime takenAt}) async {
    await _db.transaction((txn) async {
      await txn.insert('photos', {
        'asset_id': assetId,
        'scanned_at': DateTime.now().millisecondsSinceEpoch,
        'face_count': faces.length,
        'taken_at': takenAt.millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final f in faces) {
        await txn.insert('faces', {
          'asset_id': assetId,
          'left': f.left,
          'top': f.top,
          'width': f.width,
          'height': f.height,
          'embedding': f.embedding.buffer.asUint8List(),
          'thumb': f.thumb,
          'sharpness': f.sharpness,
          'eyes_open': f.eyesOpen,
          'smile': f.smile,
          'yaw': f.yaw,
        });
      }
    });
  }

  /// Photos scanned before dates were stored.
  Future<List<String>> photosWithoutDate() async {
    final rows = await _db.query('photos',
        columns: ['asset_id'], where: 'taken_at IS NULL');
    return [for (final r in rows) r['asset_id'] as String];
  }

  Future<void> setTakenAt(Map<String, DateTime> dates) async {
    final batch = _db.batch();
    dates.forEach((id, t) => batch.update(
        'photos', {'taken_at': t.millisecondsSinceEpoch},
        where: 'asset_id = ?', whereArgs: [id]));
    await batch.commit(noResult: true);
  }

  Future<bool> isScanned(String assetId) async => (await _db.query('photos',
          columns: ['asset_id'], where: 'asset_id = ?', whereArgs: [assetId]))
      .isNotEmpty;

  /// Every face found in [assetId] with its box and who it is (if known).
  Future<List<({Rect box, PhotoPerson? person})>> facesInPhoto(String assetId) async {
    final rows = await _db.rawQuery('''
      SELECT f.left, f.top, f.width, f.height, f.thumb, p.id, p.name
      FROM faces f LEFT JOIN persons p ON p.id = f.person_id
      WHERE f.asset_id = ?''', [assetId]);
    return [
      for (final r in rows)
        (
          box: Rect.fromLTWH((r['left'] as num).toDouble(), (r['top'] as num).toDouble(),
              (r['width'] as num).toDouble(), (r['height'] as num).toDouble()),
          person: r['id'] == null
              ? null
              : PhotoPerson(r['id'] as int, r['name'] as String?, r['thumb'] as Uint8List),
        ),
    ];
  }

  /// Everyone recognised in [assetId], for the photo info sheet.
  Future<List<PhotoPerson>> peopleInPhoto(String assetId) async {
    final rows = await _db.rawQuery('''
      SELECT p.id, p.name, f.thumb FROM faces f JOIN persons p ON p.id = f.person_id
      WHERE f.asset_id = ? ORDER BY f.left''', [assetId]);
    return [
      for (final r in rows)
        PhotoPerson(r['id'] as int, r['name'] as String?, r['thumb'] as Uint8List),
    ];
  }

  // ---- Categories ----

  /// Photos that still need categorising at [version].
  Future<Set<String>> taggedAssetIds(int version) async {
    final rows = await _db.query('photos',
        columns: ['asset_id'], where: 'tag_version >= ?', whereArgs: [version]);
    return {for (final r in rows) r['asset_id'] as String};
  }

  Future<void> saveTags(String assetId, Set<String> tags, int version) async {
    await _db.transaction((txn) async {
      await txn.delete('photo_tags', where: 'asset_id = ?', whereArgs: [assetId]);
      for (final t in tags) {
        await txn.insert('photo_tags', {'asset_id': assetId, 'tag': t},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.update('photos', {'tag_version': version},
          where: 'asset_id = ?', whereArgs: [assetId]);
    });
  }

  /// Face facts for a photo scanned earlier, so it can be tagged without
  /// running face detection again.
  Future<
      ({
        int count,
        double maxArea,
        double? minSharpness,
        double? avgSharpness,
        double? minEyes,
        double? maxSmile,
        double? maxYaw,
      })> faceStats(String assetId) async {
    final rows = await _db.rawQuery('''
      SELECT COUNT(*) AS n, MAX(width * height) AS area, MIN(sharpness) AS sharp,
        AVG(sharpness) AS avg_sharp,
        MIN(CASE WHEN width >= $eyeReadableWidth THEN eyes_open END) AS eyes,
        MAX(CASE WHEN width >= $eyeReadableWidth THEN smile END) AS smile,
        MAX(CASE WHEN width >= $eyeReadableWidth THEN ABS(yaw) END) AS yaw
      FROM faces WHERE asset_id = ?''', [assetId]);
    final r = rows.first;
    double? d(String k) => (r[k] as num?)?.toDouble();
    return (
      count: r['n'] as int,
      maxArea: d('area') ?? 0,
      minSharpness: d('sharp'),
      avgSharpness: d('avg_sharp'),
      minEyes: d('eyes'),
      maxSmile: d('smile'),
      maxYaw: d('yaw'),
    );
  }

  /// Duplicate fingerprint, place and overall quality of a photo.
  Future<void> savePhotoMeta(String assetId,
      {required int? hash, double? lat, double? lng, required double quality}) =>
      _db.update('photos', {'dhash': hash, 'lat': lat, 'lng': lng, 'quality': quality},
          where: 'asset_id = ?', whereArgs: [assetId]);

  // ---- Duplicates ----

  Future<List<PhotoFingerprint>> fingerprints() async {
    final rows = await _db.rawQuery('''
      SELECT asset_id, dhash, taken_at, quality, hidden FROM photos
      WHERE dhash IS NOT NULL AND taken_at IS NOT NULL ORDER BY taken_at''');
    return [
      for (final r in rows)
        PhotoFingerprint(
          r['asset_id'] as String,
          r['dhash'] as int,
          r['taken_at'] as int,
          (r['quality'] as num?)?.toDouble() ?? 0,
          (r['hidden'] as int) == 1,
        ),
    ];
  }

  /// Photos with two or more faces, in time order, with every face's
  /// readings. Hidden photos are left out.
  Future<List<GroupShot>> groupShots({int? tripId}) async {
    final trip = tripId == null ? '' : 'JOIN trip_photos tp ON tp.asset_id = ph.asset_id AND tp.trip_id = ?';
    final rows = await _db.rawQuery('''
      SELECT ph.asset_id, ph.taken_at, f.width, f.eyes_open, f.smile, f.sharpness
      FROM photos ph JOIN faces f ON f.asset_id = ph.asset_id $trip
      WHERE ph.face_count >= 2 AND ph.hidden = 0 AND ph.taken_at IS NOT NULL
      ORDER BY ph.taken_at, ph.asset_id''', [?tripId]);
    final out = <GroupShot>[];
    for (final r in rows) {
      final id = r['asset_id'] as String;
      if (out.isEmpty || out.last.assetId != id) out.add(GroupShot(id, r['taken_at'] as int, []));
      final w = (r['width'] as num).toDouble();
      final readable = w >= eyeReadableWidth;
      out.last.faces.add(ShotFace(
        w,
        readable ? (r['eyes_open'] as num?)?.toDouble() : null,
        readable ? (r['smile'] as num?)?.toDouble() : null,
        (r['sharpness'] as num?)?.toDouble(),
      ));
    }
    return [for (final s in out) if (s.faces.length >= 2) s];
  }

  /// Hidden photos stay on the phone but leave people, best-of and Explore.
  Future<void> setHidden(Iterable<String> assetIds, bool hidden) async {
    final batch = _db.batch();
    for (final id in assetIds) {
      batch.update('photos', {'hidden': hidden ? 1 : 0},
          where: 'asset_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Forgets photos that were removed from the phone.
  Future<void> forgetPhotos(Iterable<String> assetIds) async {
    final batch = _db.batch();
    for (final id in assetIds) {
      batch.delete('photos', where: 'asset_id = ?', whereArgs: [id]);
      batch.delete('trip_photos', where: 'asset_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  // ---- Together / timeline ----

  /// Photos every one of [personIds] appears in, newest first.
  Future<List<String>> photosWithAll(List<int> personIds, {int? tripId}) async {
    if (personIds.isEmpty) return const [];
    final marks = List.filled(personIds.length, '?').join(',');
    final (scope, args) = _photoScope(tripId, null);
    final rows = await _db.rawQuery('''
      SELECT f.asset_id FROM faces f JOIN photos ph ON ph.asset_id = f.asset_id $scope
      WHERE f.person_id IN ($marks) AND ph.hidden = 0
      GROUP BY f.asset_id HAVING COUNT(DISTINCT f.person_id) = ?
      ORDER BY MAX(ph.taken_at) DESC''', [...args, ...personIds, personIds.length]);
    return [for (final r in rows) r['asset_id'] as String];
  }

  /// Scanned photos, newest first, optionally only in [tripId] / [dates].
  Future<List<String>> photosIn({int? tripId, DaySpan? dates}) async {
    final trip = tripId == null ? '' : 'JOIN trip_photos tp ON tp.asset_id = ph.asset_id AND tp.trip_id = ?';
    final rows = await _db.rawQuery('''
      SELECT ph.asset_id FROM photos ph $trip
      WHERE ph.hidden = 0 ${dates == null ? '' : 'AND ph.taken_at BETWEEN ? AND ?'}
      ORDER BY ph.taken_at DESC''', [
      ?tripId,
      if (dates != null) ...[dates.start.millisecondsSinceEpoch, dates.end.millisecondsSinceEpoch],
    ]);
    return [for (final r in rows) r['asset_id'] as String];
  }

  /// Photos with a known location (not 0,0), oldest first, optionally only
  /// on [tripId] and within [dates].
  Future<List<({String id, DateTime at, double lat, double lng})>> photoLocations(
      {int? tripId, DaySpan? dates}) async {
    final trip = tripId == null ? '' : 'JOIN trip_photos tp ON tp.asset_id = ph.asset_id AND tp.trip_id = ?';
    final rows = await _db.rawQuery('''
      SELECT ph.asset_id, ph.taken_at, ph.lat, ph.lng FROM photos ph $trip
      WHERE ph.hidden = 0 AND ph.lat IS NOT NULL AND ph.lng IS NOT NULL AND ph.taken_at IS NOT NULL
        AND NOT (ph.lat = 0 AND ph.lng = 0)
        ${dates == null ? '' : 'AND ph.taken_at BETWEEN ? AND ?'}
      ORDER BY ph.taken_at''', [
      ?tripId,
      if (dates != null) ...[dates.start.millisecondsSinceEpoch, dates.end.millisecondsSinceEpoch],
    ]);
    return [
      for (final r in rows)
        (
          id: r['asset_id'] as String,
          at: DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int),
          lat: (r['lat'] as num).toDouble(),
          lng: (r['lng'] as num).toDouble(),
        ),
    ];
  }

  /// Scanned photos with no location saved (scanned before the app could
  /// read locations, or taken with location off).
  Future<List<String>> photosWithoutLocation() async {
    final rows = await _db.rawQuery('SELECT asset_id FROM photos WHERE lat IS NULL AND hidden = 0');
    return [for (final r in rows) r['asset_id'] as String];
  }

  /// Photos checked and found to have no location: stored as 0,0 (which
  /// every location query skips) so they aren't checked again.
  Future<void> markNoLocation(Iterable<String> ids) async {
    final batch = _db.batch();
    for (final id in ids) {
      batch.update('photos', {'lat': 0.0, 'lng': 0.0}, where: 'asset_id = ? AND lat IS NULL', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> setLocations(Map<String, ({double lat, double lng})> at) async {
    final batch = _db.batch();
    at.forEach((id, p) => batch.update('photos', {'lat': p.lat, 'lng': p.lng}, where: 'asset_id = ?', whereArgs: [id]));
    await batch.commit(noResult: true);
  }

  /// How many photos have a known location.
  Future<int> locatedCount() async {
    final rows = await _db.rawQuery('''
      SELECT COUNT(*) AS n FROM photos
      WHERE hidden = 0 AND lat IS NOT NULL AND lng IS NOT NULL AND NOT (lat = 0 AND lng = 0)''');
    return rows.first['n'] as int;
  }

  /// A trip's photos in time order with where they were taken.
  Future<List<({String id, DateTime? at, double? lat, double? lng})>> tripTimeline(
      int tripId) async {
    final rows = await _db.rawQuery('''
      SELECT ph.asset_id, ph.taken_at,
        -- 0,0 marks "checked, no location" (see markNoLocation).
        CASE WHEN ph.lat = 0 AND ph.lng = 0 THEN NULL ELSE ph.lat END AS lat,
        CASE WHEN ph.lat = 0 AND ph.lng = 0 THEN NULL ELSE ph.lng END AS lng
      FROM trip_photos tp JOIN photos ph ON ph.asset_id = tp.asset_id
      WHERE tp.trip_id = ? AND ph.hidden = 0 ORDER BY ph.taken_at''', [tripId]);
    return [
      for (final r in rows)
        (
          id: r['asset_id'] as String,
          at: r['taken_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int),
          lat: (r['lat'] as num?)?.toDouble(),
          lng: (r['lng'] as num?)?.toDouble(),
        ),
    ];
  }

  // ---- Storage ----

  Future<Map<String, int?>> photoSizes({int? tripId}) async {
    final rows = tripId == null
        ? await _db.query('photos', columns: ['asset_id', 'bytes'])
        : await _db.rawQuery('''
            SELECT ph.asset_id, ph.bytes FROM photos ph
            JOIN trip_photos tp ON tp.asset_id = ph.asset_id WHERE tp.trip_id = ?''',
            [tripId]);
    return {for (final r in rows) r['asset_id'] as String: r['bytes'] as int?};
  }

  Future<void> setSizes(Map<String, int> sizes) async {
    final batch = _db.batch();
    sizes.forEach((id, n) => batch.update('photos', {'bytes': n},
        where: 'asset_id = ?', whereArgs: [id]));
    await batch.commit(noResult: true);
  }

  /// Every tag with how many photos have it and the newest one as a cover.
  Future<Map<String, ({int count, String cover})>> tagCounts(
      {DaySpan? dates}) async {
    final (where, args) = _dateWhere('ph', dates);
    final rows = await _db.rawQuery('''
      SELECT t.tag, COUNT(*) AS n,
        (SELECT t2.asset_id FROM photo_tags t2 JOIN photos p2 ON p2.asset_id = t2.asset_id
          WHERE t2.tag = t.tag ORDER BY p2.taken_at DESC LIMIT 1) AS cover
      FROM photo_tags t JOIN photos ph ON ph.asset_id = t.asset_id
      $where GROUP BY t.tag''', args);
    return {
      for (final r in rows)
        r['tag'] as String: (count: r['n'] as int, cover: r['cover'] as String),
    };
  }

  /// Photos with [tag], newest first.
  Future<List<String>> photosWithTag(String tag, {DaySpan? dates}) async {
    final (where, args) = _dateWhere('ph', dates);
    final rows = await _db.rawQuery('''
      SELECT t.asset_id FROM photo_tags t JOIN photos ph ON ph.asset_id = t.asset_id
      ${where.isEmpty ? 'WHERE' : '$where AND'} t.tag = ?
      ORDER BY ph.taken_at DESC''', [...args, tag]);
    return [for (final r in rows) r['asset_id'] as String];
  }

  /// A few recent photos of [tag] for a category card's rotating cover.
  Future<List<String>> tagCovers(String tag, {DaySpan? dates, int limit = 4}) async {
    final ids = await photosWithTag(tag, dates: dates);
    return ids.take(limit).toList();
  }

  /// Tags of each given photo (for filtering a person's photos).
  Future<Map<String, Set<String>>> tagsFor(Iterable<String> assetIds) async {
    final ids = assetIds.toList();
    final out = <String, Set<String>>{};
    // SQLite limits how many ? a statement may have.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, (i + 500).clamp(0, ids.length));
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
          'SELECT asset_id, tag FROM photo_tags WHERE asset_id IN ($marks)', chunk);
      for (final r in rows) {
        out.putIfAbsent(r['asset_id'] as String, () => {}).add(r['tag'] as String);
      }
    }
    return out;
  }

  static (String, List<Object>) _dateWhere(String alias, DaySpan? dates) =>
      dates == null
          ? ('', const [])
          : (
              'WHERE $alias.taken_at BETWEEN ? AND ?',
              [dates.start.millisecondsSinceEpoch, dates.end.millisecondsSinceEpoch],
            );

  // ---- Grouping ----

  /// Every face in [assetIds] (scanned photos only), with its fingerprint
  /// and crop.
  Future<List<({String assetId, Float32List embedding, Uint8List thumb})>> facesIn(List<String> assetIds) async {
    final out = <({String assetId, Float32List embedding, Uint8List thumb})>[];
    for (var i = 0; i < assetIds.length; i += 500) {
      final chunk = assetIds.sublist(i, (i + 500).clamp(0, assetIds.length));
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
          'SELECT asset_id, embedding, thumb FROM faces WHERE asset_id IN ($marks)', chunk);
      for (final r in rows) {
        out.add((assetId: r['asset_id'] as String, embedding: _floats(r['embedding']), thumb: r['thumb'] as Uint8List));
      }
    }
    return out;
  }

  Future<List<FaceRecord>> allFaces() async {
    final rows = await _db.query(
      'faces',
      columns: ['id', 'asset_id', 'embedding', 'person_id', 'locked'],
    );
    return [
      for (final r in rows)
        FaceRecord(
          id: r['id'] as int,
          assetId: r['asset_id'] as String,
          embedding: _floats(r['embedding']),
          personId: r['person_id'] as int?,
          locked: (r['locked'] as int) == 1,
        ),
    ];
  }

  /// Applies a grouping result: [assignToExisting] maps face id -> person id,
  /// and each entry of [newGroups] becomes a brand-new unnamed person.
  Future<void> applyGrouping(
    Map<int, int> assignToExisting,
    List<List<int>> newGroups,
  ) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      assignToExisting.forEach((faceId, personId) {
        batch.update('faces', {'person_id': personId},
            where: 'id = ?', whereArgs: [faceId]);
      });
      await batch.commit(noResult: true);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final group in newGroups) {
        final personId = await txn.insert('persons', {'created_at': now});
        final b = txn.batch();
        for (final faceId in group) {
          b.update('faces', {'person_id': personId},
              where: 'id = ?', whereArgs: [faceId]);
        }
        await b.commit(noResult: true);
      }
      await _deleteEmptyPersons(txn);
    });
  }

  /// Forgets every automatic, unnamed group so faces can be regrouped from
  /// scratch. Named people and hand-made decisions are kept.
  Future<void> resetAutoGroups() async {
    await _db.transaction((txn) async {
      await txn.rawUpdate('''
        UPDATE faces SET person_id = NULL
        WHERE locked = 0 AND person_id IN (SELECT id FROM persons WHERE name IS NULL)''');
      await _deleteEmptyPersons(txn);
    });
  }

  // ---- People ----

  /// Extra JOINs restricting faces `f` to a trip and/or a date range.
  static (String, List<Object>) _photoScope(int? tripId, DaySpan? dates) {
    final sql = StringBuffer();
    final args = <Object>[];
    if (tripId != null) {
      sql.write(' JOIN trip_photos tp ON tp.asset_id = f.asset_id AND tp.trip_id = ?');
      args.add(tripId);
    }
    if (dates != null) {
      sql.write(' JOIN photos pd ON pd.asset_id = f.asset_id'
          ' AND pd.taken_at BETWEEN ? AND ?');
      args.addAll([
        dates.start.millisecondsSinceEpoch,
        dates.end.millisecondsSinceEpoch,
      ]);
    }
    return (sql.toString(), args);
  }

  /// How clear a face is, for picking the one to show a person by: big,
  /// sharp, facing the camera, eyes open and smiling score higher. Readings
  /// missing on older scans count as average. [t] is the faces table alias.
  static String _faceScore(String t) => '$t.width'
      ' * MIN(MAX(COALESCE($t.sharpness, 80), 0), 400)'
      ' * (1 - MIN(ABS(COALESCE($t.yaw, 15)), 60) / 90.0)'
      ' * MIN(MAX(COALESCE($t.eyes_open, 0.8), 0.15), 1)'
      ' * (0.7 + 0.3 * COALESCE($t.smile, 0.5))';

  /// A guess only counts once it's at least this sure either way.
  static const _sureGuess = 0.75;

  /// A person's gender code: set by hand, else a sure enough guess.
  static String _genderOf(String p) => "COALESCE($p.gender, CASE"
      " WHEN $p.gender_guess >= $_sureGuess THEN 'f'"
      " WHEN $p.gender_guess <= ${1 - _sureGuess} THEN 'm' END)";

  /// People with at least one face, optionally only in [tripId] / [dates] /
  /// [groupId]. People marked "not in our group" are left out unless
  /// [ignored] is true, which returns only them.
  Future<List<PersonSummary>> people(
      {int? tripId, DaySpan? dates, int? groupId, bool ignored = false}) async {
    final (scope, args) = _photoScope(tripId, dates);
    final group = groupId == null
        ? ''
        : 'JOIN person_group_members gm ON gm.person_id = p.id AND gm.group_id = $groupId';
    final rows = await _db.rawQuery('''
      SELECT p.id, p.name, p.nickname, COUNT(DISTINCT f.asset_id) AS photo_count,
        ${_genderOf('p')} AS gender, p.gender IS NULL AS guessed,
        COALESCE(
          (SELECT thumb FROM faces cf WHERE cf.id = p.cover_face_id AND cf.person_id = p.id),
          (SELECT thumb FROM faces c WHERE c.person_id = p.id
             ORDER BY c.locked DESC, ${_faceScore('c')} DESC LIMIT 1)
        ) AS cover
      FROM persons p JOIN faces f ON f.person_id = p.id
        JOIN photos ph0 ON ph0.asset_id = f.asset_id AND ph0.hidden = 0
        $scope $group
      WHERE p.ignored = ${ignored ? 1 : 0}
      GROUP BY p.id
      ORDER BY (p.name IS NULL), photo_count DESC''', args);
    return [
      for (final r in rows)
        PersonSummary(
          id: r['id'] as int,
          name: r['name'] as String?,
          nickname: r['nickname'] as String?,
          photoCount: r['photo_count'] as int,
          coverThumb: r['cover'] as Uint8List?,
          gender: Gender.fromCode(r['gender'] as String?),
          genderGuessed: r['guessed'] == 1,
        ),
    ];
  }

  /// Sets a person's gender by hand; null goes back to the app's guess.
  Future<void> setGender(int personId, Gender? gender) =>
      _db.update('persons', {'gender': gender?.code}, where: 'id = ?', whereArgs: [personId]);

  /// People the app hasn't guessed a gender for yet.
  Future<List<int>> peopleWithoutGenderGuess() async {
    final rows = await _db.rawQuery('''
      SELECT DISTINCT p.id FROM persons p JOIN faces f ON f.person_id = p.id
      WHERE p.gender_guess IS NULL AND p.ignored = 0''');
    return [for (final r in rows) r['id'] as int];
  }

  Future<void> saveGenderGuesses(Map<int, double> chanceFemale) async {
    final batch = _db.batch();
    chanceFemale.forEach((id, p) => batch.update('persons', {'gender_guess': p}, where: 'id = ?', whereArgs: [id]));
    await batch.commit(noResult: true);
  }

  /// Photos with at least one person of [gender] in them, newest first.
  Future<List<String>> photosWithGender(Gender gender, {int? tripId}) async {
    final (scope, args) = _photoScope(tripId, null);
    final rows = await _db.rawQuery('''
      SELECT f.asset_id FROM faces f JOIN persons p ON p.id = f.person_id
        JOIN photos ph ON ph.asset_id = f.asset_id $scope
      WHERE ${_genderOf('p')} = ? AND p.ignored = 0 AND ph.hidden = 0
      GROUP BY f.asset_id
      ORDER BY MAX(ph.taken_at) DESC''', [...args, gender.code]);
    return [for (final r in rows) r['asset_id'] as String];
  }

  Future<void> setNickname(int personId, String? nickname) => _db.update(
      'persons', {'nickname': (nickname?.trim().isEmpty ?? true) ? null : nickname!.trim()},
      where: 'id = ?', whereArgs: [personId]);

  /// "Not in our group": hide a stranger everywhere (or bring them back).
  Future<void> setIgnored(int personId, bool ignored) async {
    await _db.update('persons', {'ignored': ignored ? 1 : 0},
        where: 'id = ?', whereArgs: [personId]);
    // Their faces stop asking for review.
    if (ignored) await skipGroup(personId);
  }

  Future<void> setCover(int personId, int faceId) => _db.update(
      'persons', {'cover_face_id': faceId}, where: 'id = ?', whereArgs: [personId]);

  /// The clearest few faces of a person, best first, to take turns as
  /// their picture: only ones nearly as good as the best, and from moments
  /// apart, so a burst of the same shot doesn't fill the set. Just the
  /// chosen picture when one was picked by hand.
  Future<List<Uint8List>> bestFaces(int personId, {int limit = 5}) async {
    final chosen = await _db.rawQuery('''
      SELECT f.thumb FROM persons p JOIN faces f ON f.id = p.cover_face_id AND f.person_id = p.id
      WHERE p.id = ?''', [personId]);
    if (chosen.isNotEmpty) return [chosen.first['thumb'] as Uint8List];
    final rows = await _db.rawQuery('''
      SELECT f.thumb, ph.taken_at, ${_faceScore('f')} AS score
      FROM faces f JOIN photos ph ON ph.asset_id = f.asset_id AND ph.hidden = 0
      WHERE f.person_id = ?
      ORDER BY f.locked DESC, score DESC LIMIT 30''', [personId]);
    final picked = <Uint8List>[];
    final times = <int>[];
    final best = rows.isEmpty ? 0.0 : (rows.first['score'] as num?)?.toDouble() ?? 0;
    for (final r in rows) {
      if (picked.length >= limit) break;
      final score = (r['score'] as num?)?.toDouble() ?? 0;
      if (picked.isNotEmpty && score < best * _clearEnough) continue;
      final at = r['taken_at'] as int?;
      if (at != null && times.any((t) => (t - at).abs() < _apart.inMilliseconds)) continue;
      picked.add(r['thumb'] as Uint8List);
      if (at != null) times.add(at);
    }
    return picked;
  }

  /// A face takes a turn only if it's at least this clear next to the best.
  static const _clearEnough = 0.55;

  /// Faces from photos closer together than this count as the same moment.
  static const _apart = Duration(minutes: 2);

  // ---- Groups of people ----

  Future<List<PersonGroup>> groups() async {
    final rows = await _db.query('person_groups', orderBy: 'name COLLATE NOCASE');
    final members = await _db.query('person_group_members');
    return [
      for (final r in rows)
        PersonGroup(r['id'] as int, r['name'] as String, {
          for (final m in members)
            if (m['group_id'] == r['id']) m['person_id'] as int,
        }),
    ];
  }

  /// Creates ([id] null) or replaces a group.
  Future<void> saveGroup(int? id, String name, Set<int> members) async {
    await _db.transaction((txn) async {
      final gid = id ??
          await txn.insert('person_groups', {'name': name.trim()});
      if (id != null) {
        await txn.update('person_groups', {'name': name.trim()},
            where: 'id = ?', whereArgs: [id]);
        await txn.delete('person_group_members', where: 'group_id = ?', whereArgs: [id]);
      }
      for (final m in members) {
        await txn.insert('person_group_members', {'group_id': gid, 'person_id': m});
      }
    });
  }

  Future<void> deleteGroup(int id) =>
      _db.delete('person_groups', where: 'id = ?', whereArgs: [id]);

  // ---- Merge suggestions ----

  Future<Set<(int, int)>> dismissedPairs() async {
    final rows = await _db.query('dismissed_pairs');
    return {for (final r in rows) (r['a'] as int, r['b'] as int)};
  }

  /// "Not the same person": stop suggesting this pair.
  Future<void> dismissPair(int a, int b) => _db.insert(
      'dismissed_pairs', {'a': a < b ? a : b, 'b': a < b ? b : a},
      conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<Set<int>> namedPersonIds() async {
    final rows =
        await _db.query('persons', columns: ['id'], where: 'name IS NOT NULL');
    return {for (final r in rows) r['id'] as int};
  }

  Future<PersonSummary?> person(int id) async {
    for (final ignored in [false, true]) {
      for (final p in await people(ignored: ignored)) {
        if (p.id == id) return p;
      }
    }
    return null;
  }

  Future<bool> isIgnored(int id) async {
    final rows = await _db.query('persons',
        columns: ['ignored'], where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty && rows.first['ignored'] == 1;
  }

  /// One entry per photo the person is in (their biggest face if several).
  Future<List<PersonPhoto>> photosOf(int personId,
      {int? tripId, DaySpan? dates}) async {
    final (scope, args) = _photoScope(tripId, dates);
    final rows = await _db.rawQuery('''
      SELECT f.asset_id, f.left, f.top, f.width, f.height, f.sharpness,
        f.eyes_open, f.smile, ph.face_count, ph.taken_at
      FROM faces f JOIN photos ph ON ph.asset_id = f.asset_id $scope
      WHERE f.person_id = ? AND ph.hidden = 0
      ORDER BY COALESCE(ph.taken_at, ph.scanned_at) DESC''', [...args, personId]);
    final byAsset = <String, PersonPhoto>{};
    for (final r in rows) {
      final taken = r['taken_at'] as int?;
      final photo = PersonPhoto(
        assetId: r['asset_id'] as String,
        takenAt:
            taken == null ? null : DateTime.fromMillisecondsSinceEpoch(taken),
        face: Rect.fromLTWH(
          (r['left'] as num).toDouble(),
          (r['top'] as num).toDouble(),
          (r['width'] as num).toDouble(),
          (r['height'] as num).toDouble(),
        ),
        sharpness: (r['sharpness'] as num?)?.toDouble(),
        // Too small to read reliably: treat as unknown.
        eyesOpen: (r['width'] as num) < eyeReadableWidth
            ? null
            : (r['eyes_open'] as num?)?.toDouble(),
        smile: (r['width'] as num) < eyeReadableWidth
            ? null
            : (r['smile'] as num?)?.toDouble(),
        faceCount: r['face_count'] as int,
      );
      final prev = byAsset[photo.assetId];
      if (prev == null || photo.face.width > prev.face.width) {
        byAsset[photo.assetId] = photo;
      }
    }
    return byAsset.values.toList();
  }

  Future<List<FaceThumb>> facesOf(int personId, {int? limit}) async {
    final rows = await _db.query('faces',
        columns: ['id', 'asset_id', 'thumb'],
        where: 'person_id = ?',
        whereArgs: [personId],
        orderBy: '${_faceScore('faces')} DESC',
        limit: limit);
    return [
      for (final r in rows)
        FaceThumb(r['id'] as int, r['asset_id'] as String,
            r['thumb'] as Uint8List),
    ];
  }

  /// Names a person. If someone with that name already exists, this person
  /// is merged into them; returns the id that now holds the faces.
  Future<int> renamePerson(int id, String name) async {
    final trimmed = cleanName(name);
    final existing = trimmed.isEmpty ? null : await _personNamed(trimmed);
    if (existing != null && existing != id) {
      await mergePeople(existing, [id]);
      return existing;
    }
    await _db.transaction((txn) async {
      await txn.update('persons', {'name': trimmed.isEmpty ? null : trimmed},
          where: 'id = ?', whereArgs: [id]);
      // Naming a person confirms their current faces.
      await txn.update('faces', {'locked': 1, 'reviewed': 1},
          where: 'person_id = ?', whereArgs: [id]);
    });
    return id;
  }

  Future<int?> _personNamed(String name) async {
    final rows = await _db.rawQuery('''
      SELECT p.id FROM persons p
      WHERE p.name = ? COLLATE NOCASE
        AND EXISTS (SELECT 1 FROM faces f WHERE f.person_id = p.id)
      LIMIT 1''', [name]);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// A name as typed, without stray spaces (inside ones included).
  static String cleanName(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<int> createPerson(String name) => _db.insert('persons', {
        'name': cleanName(name),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

  /// "Not this person": the face leaves the group and is ignored from now on.
  Future<FaceSnapshot> rejectFace(int faceId) async {
    final before = await _snapshot('id = ?', [faceId]);
    await _db.update('faces', {'person_id': null, 'locked': 1, 'reviewed': 1},
        where: 'id = ?', whereArgs: [faceId]);
    return before;
  }

  /// Faces nobody was matched with (often half turned or partly hidden),
  /// newest photos first, for moving to a person by hand.
  Future<List<FaceThumb>> unmatchedFaces() async {
    final rows = await _db.rawQuery('''
      SELECT f.id, f.asset_id, f.thumb FROM faces f
        JOIN photos ph ON ph.asset_id = f.asset_id AND ph.hidden = 0
      WHERE f.person_id IS NULL
      ORDER BY ph.taken_at DESC, f.id DESC''');
    return [
      for (final r in rows) FaceThumb(r['id'] as int, r['asset_id'] as String, r['thumb'] as Uint8List),
    ];
  }

  Future<int> unmatchedCount() async {
    final rows = await _db.rawQuery('''
      SELECT COUNT(*) AS n FROM faces f JOIN photos ph ON ph.asset_id = f.asset_id AND ph.hidden = 0
      WHERE f.person_id IS NULL''');
    return rows.first['n'] as int;
  }

  /// Moves [faceIds] to [personId] by hand, for good (grouping won't move
  /// them back). Returns how they were, for undo.
  Future<FaceSnapshot> assignFaces(List<int> faceIds, int personId) async {
    if (faceIds.isEmpty) return FaceSnapshot(const []);
    final marks = List.filled(faceIds.length, '?').join(',');
    final before = await _snapshot('id IN ($marks)', faceIds);
    await _db.transaction((txn) async {
      await txn.rawUpdate(
          'UPDATE faces SET person_id = ?, locked = 1, reviewed = 1 WHERE id IN ($marks)', [personId, ...faceIds]);
      // More faces now: guess again.
      await txn.update('persons', {'gender_guess': null}, where: 'id = ?', whereArgs: [personId]);
    });
    return before;
  }

  /// Confirms [faceId] as [personId] (from the review screen).
  Future<void> assignFace(int faceId, int personId) => _db.update(
      'faces', {'person_id': personId, 'locked': 1, 'reviewed': 1},
      where: 'id = ?', whereArgs: [faceId]);

  /// Hides faces from the review screen without deciding who they are.
  Future<void> markReviewed(Iterable<int> faceIds) async {
    final batch = _db.batch();
    for (final id in faceIds) {
      batch.update('faces', {'reviewed': 1},
          where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// Moves every face of [others] into [target].
  Future<FaceSnapshot> mergePeople(int target, List<int> others) async {
    if (others.isEmpty) return FaceSnapshot(const []);
    final ids = [target, ...others];
    final marks = List.filled(ids.length, '?').join(',');
    final before = await _snapshot('person_id IN ($marks)', ids);
    await _db.transaction((txn) async {
      await txn.rawUpdate(
          'UPDATE faces SET person_id = ?, locked = 1, reviewed = 1 WHERE person_id IN ($marks)',
          [target, ...ids]);
      // More faces now: guess again.
      await txn.update('persons', {'gender_guess': null}, where: 'id = ?', whereArgs: [target]);
    });
    return before;
  }

  /// Puts faces back exactly as captured by [snapshot]. Person rows are only
  /// cleaned up on the next grouping, so the old people still exist.
  Future<void> restore(FaceSnapshot snapshot) async {
    final batch = _db.batch();
    for (final r in snapshot.rows) {
      batch.update('faces', {'person_id': r.personId, 'locked': r.locked ? 1 : 0},
          where: 'id = ?', whereArgs: [r.id]);
    }
    await batch.commit(noResult: true);
  }

  Future<FaceSnapshot> _snapshot(String where, List<Object?> args) async {
    final rows = await _db.query('faces',
        columns: ['id', 'person_id', 'locked'], where: where, whereArgs: args);
    return FaceSnapshot([
      for (final r in rows)
        (
          id: r['id'] as int,
          personId: r['person_id'] as int?,
          locked: (r['locked'] as int) == 1,
        ),
    ]);
  }

  // ---- Review ----

  /// Faces with no person that the user hasn't looked at yet.
  Future<List<UnsortedFace>> unsortedFaces() async {
    final rows = await _db.query('faces',
        columns: ['id', 'embedding', 'thumb'],
        where: 'person_id IS NULL AND locked = 0 AND reviewed = 0');
    return [
      for (final r in rows)
        UnsortedFace(
            r['id'] as int, _floats(r['embedding']), r['thumb'] as Uint8List),
    ];
  }

  /// Unnamed groups that still have faces nobody has confirmed.
  Future<List<PersonSummary>> unreviewedGroups() async {
    final all = await people();
    final pending = await _db.rawQuery('''
      SELECT DISTINCT person_id FROM faces
      WHERE person_id IS NOT NULL AND reviewed = 0''');
    final ids = {for (final r in pending) r['person_id'] as int};
    return [
      for (final p in all)
        if (p.name == null && ids.contains(p.id)) p,
    ];
  }

  /// Marks every face of an unnamed group as seen, so it leaves the queue.
  Future<void> skipGroup(int personId) => _db.update('faces', {'reviewed': 1},
      where: 'person_id = ?', whereArgs: [personId]);

  Future<void> clearAll() async {
    await _db.transaction((txn) async {
      await txn.delete('faces');
      await txn.delete('photo_tags');
      await txn.delete('photos');
      await txn.delete('sent');
      await txn.delete('transfers');
      await txn.delete('devices');
      await txn.delete('person_group_members');
      await txn.delete('person_groups');
      await txn.delete('dismissed_pairs');
      await txn.delete('persons');
      await txn.delete('trip_photos');
      await txn.delete('trips');
    });
  }

  /// Where the database file lives (for backup / restore).
  static Future<String> filePath() async =>
      p.join(await getDatabasesPath(), 'photo_organizer.db');

  Future<void> close() => _db.close();

  Future<void> _deleteEmptyPersons(Transaction txn) => txn.rawDelete(
      'DELETE FROM persons WHERE id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)');

  // Copy into an aligned buffer; BLOB bytes may not be 4-byte aligned.
  static Float32List _floats(Object? blob) => Float32List.fromList(
      Uint8List.fromList(blob as Uint8List).buffer.asFloat32List());
}
