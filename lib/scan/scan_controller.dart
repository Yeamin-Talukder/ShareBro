import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../data/gallery.dart';
import '../data/group_match.dart';
import '../data/profile.dart';
import '../face/clustering.dart';
import '../face/face_engine.dart';
import '../face/gender.dart';
import '../face/tags.dart';
import '../share/receive.dart' show receivedAlbum;
import '../share/send_center.dart';
import '../share/server.dart' show FindLink, WebShare;
import '../ui/fast_thumb.dart' show FastThumb;
import 'background.dart';

/// Longest side of the image the face finder looks at. Bigger finds smaller
/// faces in group shots but is slower.
const _scanSize = 1600;

/// How far below a sure match a face still gets a "Is this them?".
const _unsureRange = 0.08;
const _pageSize = 200;

/// Faces re-fingerprinted per step of a face model upgrade.
const _upgradeBatch = 64;

/// Numbers per fingerprint from the current face model.
const _embeddingSize = 512;

/// Photos scanned at the same time.
const _inFlight = 3;

/// Photos whose location is read at the same time.
const _locateBatch = 24;

/// Clearest faces per person the gender guess looks at.
const _genderFaces = 6;

/// How many of the latest faces the scan screen shows.
const _recentLimit = 60;

/// Counts worth a little celebration on the scan screen.
const _photoMilestones = [100, 250, 500, 1000, 2000, 3000, 5000, 10000];
const _faceMilestones = [50, 100, 250, 500, 1000, 2500, 5000];

/// Faces at least this similar to a named person are offered in review.
const _suggestMin = 0.22;

const _strictnessKey = 'strictness';
const _autoScanKey = 'auto_scan';
const _appLockKey = 'app_lock';

/// People this much below the auto-merge level are offered as "same person?".
const _mergeHintRange = 0.10;
const _maxMergeHints = 15;

/// A lone face at least this close to a named person (shown as "75%
/// match") joins them without asking in Review.
const _autoAccept = 0.75;

/// Similarity where the app is least sure whether a lone face is someone.
const _unsure = 0.30;

/// Something to decide on the review screen.
sealed class ReviewItem {}

/// An unnamed group: "Who is this?"
class GroupReview extends ReviewItem {
  GroupReview(this.person, this.faces);

  final PersonSummary person;
  final List<FaceThumb> faces;
}

/// Two people who look alike: "Same person?"
class MergeReview extends ReviewItem {
  MergeReview(this.a, this.b, this.facesA, this.facesB, this.similarity);

  final PersonSummary a, b;
  final List<FaceThumb> facesA, facesB;
  final double similarity;
}

/// A lone face that looks like someone already named: "Is this Rahim?"
class FaceReview extends ReviewItem {
  FaceReview(this.faceId, this.thumb, this.person, this.similarity);

  final int faceId;
  final Uint8List thumb;
  final PersonSummary person;
  final double similarity;
}

/// Runs scans and grouping, and tells the UI what's happening.
class ScanController extends ChangeNotifier {
  ScanController(this.db);

  final AppDb db;
  FaceEngine? _engine;

  bool running = false;
  bool _cancel = false;
  String? albumName;
  int? tripId;
  int total = 0;
  int done = 0;
  int skipped = 0;
  int facesFound = 0;
  String? error;
  DateTime? _startedAt;

  /// Newest first; drives the live face stream on the scan screen.
  final List<Uint8List> recentFaces = [];

  /// The photo being scanned right now, with the faces found in it, for the
  /// live preview. [previewId] changes with every photo.
  Uint8List? preview;
  double previewAspect = 1;
  List<Rect> previewFaces = const [];
  List<Uint8List> previewThumbs = const [];
  int previewId = 0;

  /// Rough count of different people seen during this scan (groups of 2+
  /// similar faces), for the live counter. The real grouping runs at the end.
  int peopleSoFar = 0;
  final List<Float32List> _liveSums = [];
  final List<int> _liveCounts = [];

  final _milestones = StreamController<String>.broadcast();

  /// "1,000 photos scanned!" and similar, as they happen.
  Stream<String> get milestones => _milestones.stream;

  /// People in the trip once the last scan finished (null while scanning).
  int? peopleFound;

  double strictness = GroupingThresholds.defaultStrictness;

  /// Bumped whenever the people list may have changed.
  int revision = 0;

  /// Scan new photos in already-scanned albums by themselves.
  bool autoScanEnabled = true;

  /// Ask for fingerprint / face / screen lock when opening the app.
  bool appLock = false;

  Timer? _autoScanTimer;
  AppLifecycleListener? _lifecycle;

  /// Sending to friends' phones and web galleries (LocalSend protocol).
  late final SendCenter sharing;

  /// Your face, set up once in Profile.
  FaceProfile profile = FaceProfile(faces: const []);

  Future<void> load() async {
    sharing = await SendCenter.create(db);
    // Photos friends send us get scanned like any other album.
    sharing.receiver.onSaved = (_) => scanReceived();
    sharing.server.onSelfie = _answerSelfie;
    profile = await FaceProfile.load(db);
    sharing.groups.profile = () => profile;
    final s = await db.setting(_strictnessKey);
    strictness = double.tryParse(s ?? '') ?? GroupingThresholds.defaultStrictness;
    autoScanEnabled = (await db.setting(_autoScanKey)) != '0';
    appLock = (await db.setting(_appLockKey)) == '1';
    backfillDates();
    unawaited(backfillLocations());
    unawaited(upgradeFaces());
    _watchForNewPhotos();
  }

  Future<void> setAutoScan(bool on) async {
    autoScanEnabled = on;
    await db.setSetting(_autoScanKey, on ? '1' : '0');
    notifyListeners();
    if (on) _queueAutoScan();
  }

  Future<void> setAppLock(bool on) async {
    appLock = on;
    await db.setSetting(_appLockKey, on ? '1' : '0');
    notifyListeners();
  }

  /// New photos (or coming back to the app) trigger a quiet scan of trips
  /// whose album has grown, a few seconds later.
  void _watchForNewPhotos() {
    _lifecycle = AppLifecycleListener(onResume: _queueAutoScan);
    _queueAutoScan(const Duration(seconds: 4));
    try {
      PhotoManager.addChangeCallback((_) => _queueAutoScan());
      PhotoManager.startChangeNotify();
    } catch (e) {
      debugPrint('Photo change notifications unavailable: $e');
    }
  }

  void _queueAutoScan([Duration delay = const Duration(seconds: 8)]) {
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer(delay, autoScan);
  }

  bool _receivedPending = false;

  /// Scans the album received photos are saved in (after the current scan,
  /// if one is running).
  Future<void> scanReceived() async {
    if (running) {
      _receivedPending = true;
      return;
    }
    // The gallery takes a moment to list newly saved photos.
    await Future<void>.delayed(const Duration(seconds: 2));
    final albums = await Gallery.albums();
    final album = albums.where((a) => a.name == receivedAlbum).firstOrNull;
    if (album != null) await scan(album);
  }

  /// Scans the first trip album that has photos the app hasn't seen yet.
  /// Date-limited trips are left alone: their range is fixed.
  Future<void> autoScan() async {
    if (!autoScanEnabled || running) return;
    try {
      final ps = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption());
      if (!ps.hasAccess) return;
      final scanned = await db.scannedAssetIds();
      for (final trip in await db.trips()) {
        if (trip.albumId.contains('@')) continue;
        final album = await Gallery.albumById(trip.albumId);
        if (album == null) continue;
        final count = await album.assetCountAsync;
        if (count == 0) continue;
        // Only the newest few are checked; new photos arrive at the top.
        final newest = await album.getAssetListRange(start: 0, end: count.clamp(1, 60));
        if (newest.any((a) => !scanned.contains(a.id))) {
          debugPrint('Auto-scanning ${trip.name}');
          await scan(album);
          return;
        }
      }
    } catch (e) {
      debugPrint('Auto-scan skipped: $e');
    }
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Reads "date taken" for photos scanned before dates were stored, so the
  /// date filter works for them too. Runs quietly after startup.
  Future<void> backfillDates() async {
    try {
      final ids = await db.photosWithoutDate();
      if (ids.isEmpty) return;
      final dates = <String, DateTime>{};
      for (final id in ids) {
        final asset = await AssetEntity.fromId(id);
        if (asset != null) dates[id] = asset.createDateTime;
        if (dates.length == 200) {
          await db.setTakenAt(dates);
          dates.clear();
        }
      }
      await db.setTakenAt(dates);
      changed();
    } catch (e) {
      debugPrint('Date backfill failed: $e');
    }
  }

  bool _locating = false;

  /// Reads where already-scanned photos were taken, for the Places map:
  /// earlier versions couldn't (Android hid it without the photo-location
  /// permission). Cheap: no rescan, just each photo's GPS tag.
  ///
  /// Each photo is checked once: ones with no location are marked so the
  /// next run skips them. Returns how many locations it found.
  Future<int> backfillLocations() async {
    if (_locating) return 0;
    _locating = true;
    var saved = 0;
    try {
      final ids = await db.photosWithoutLocation();
      if (ids.isEmpty) return 0;
      final none = <String>[];
      // Several at a time: each look-up is a round trip to Android.
      for (var start = 0; start < ids.length; start += _locateBatch) {
        final batch = ids.skip(start).take(_locateBatch).toList();
        final found = await Future.wait([
          for (final id in batch)
            () async {
              final ll = await (await AssetEntity.fromId(id))?.latlngAsync();
              return ll != null && (ll.latitude != 0 || ll.longitude != 0) ? (lat: ll.latitude, lng: ll.longitude) : null;
            }(),
        ]);
        final located = <String, ({double lat, double lng})>{};
        for (final (i, ll) in found.indexed) {
          ll == null ? none.add(batch[i]) : located[batch[i]] = ll;
        }
        await db.setLocations(located);
        saved += located.length;
      }
      // Only trust "no location" once some photo had one: without the
      // photo-location permission Android reports none for every photo.
      if (saved > 0 || await db.locatedCount() > 0) await db.markNoLocation(none);
      if (saved > 0) changed();
    } catch (e) {
      debugPrint('Location backfill failed: $e');
    } finally {
      _locating = false;
    }
    return saved;
  }

  GroupingThresholds get thresholds =>
      GroupingThresholds.fromStrictness(strictness);

  // ---- Profile ----

  /// The biggest face in a photo file (a selfie or an uploaded photo), or
  /// null if there's no clear one. The file is turned upright and shrunk
  /// first; the original is never changed.
  Future<NewFace?> faceInFile(String path) async {
    final tmp = p.join((await getTemporaryDirectory()).path, 'profile_${DateTime.now().microsecondsSinceEpoch}.jpg');
    try {
      final ok = await Isolate.run(() {
        final src = img.decodeImage(File(path).readAsBytesSync());
        if (src == null) return false;
        var im = img.bakeOrientation(src);
        if (math.max(im.width, im.height) > _scanSize) {
          im = im.width >= im.height
              ? img.copyResize(im, width: _scanSize)
              : img.copyResize(im, height: _scanSize);
        }
        File(tmp).writeAsBytesSync(img.encodeJpg(im, quality: 90));
        return true;
      });
      if (!ok) return null;
      _engine ??= await FaceEngine.load();
      final faces = await _engine!.analyze(tmp);
      if (faces.isEmpty) return null;
      return faces.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
    } finally {
      final f = File(tmp);
      if (await f.exists()) await f.delete();
    }
  }

  /// Adds the face in each of [paths] to your profile. Returns how many
  /// had a clear face.
  Future<int> addProfilePhotos(List<String> paths, FaceSource source) async {
    final found = <NewFace>[];
    for (final path in paths) {
      try {
        final f = await faceInFile(path);
        if (f != null) found.add(f);
      } catch (e) {
        debugPrint('No face read from $path: $e');
      }
    }
    if (found.isEmpty) return 0;
    // The sharpest, biggest face makes the avatar.
    final best = found.reduce((a, b) => a.width * a.sharpness >= b.width * b.sharpness ? a : b);
    profile = FaceProfile(
      faces: [if (profile.personId == null) ...profile.faces],
      thumb: profile.personId == null ? profile.thumb : null,
      source: source,
    ).adding([for (final f in found) f.embedding], thumb: best.thumb, source: source);
    await profile.save(db);
    sharing.groups.refreshMe();
    notifyListeners();
    return found.length;
  }

  static const _faceModelKey = 'face_model';

  /// Stored faces are being redone for a new face model (shown like a scan).
  bool upgrading = false;

  /// After the app switches face models, every stored face gets a new
  /// fingerprint from its saved crop (no photos are rescanned), your
  /// profile is rebuilt, and faces are grouped again with the new model.
  /// Runs once per model; picks up again next launch if interrupted.
  Future<void> upgradeFaces() async {
    if (running || await db.setting(_faceModelKey) == faceModelId) return;
    final count = await db.faceCount();
    if (count == 0) {
      await db.setSetting(_faceModelKey, faceModelId);
      return;
    }
    running = upgrading = true;
    _cancel = false;
    error = null;
    albumName = 'Updating face matching';
    done = skipped = facesFound = 0;
    peopleFound = null;
    recentFaces.clear();
    preview = null;
    total = count;
    notifyListeners();
    await ScanNotification.start('Updating face matching…');
    try {
      _engine ??= await FaceEngine.load();
      var after = 0;
      while (true) {
        final crops = await db.faceCrops(after: after, limit: _upgradeBatch);
        if (crops.isEmpty) break;
        final fresh = await _engine!.embedCrops([for (final c in crops) c.thumb]);
        await db.setEmbeddings({
          for (final (i, c) in crops.indexed)
            // An unreadable crop gets an empty fingerprint: it matches no one
            // instead of mixing old and new kinds.
            c.id: fresh[i] ?? Float32List(_embeddingSize),
        });
        after = crops.last.id;
        done += crops.length;
        notifyListeners();
        ScanNotification.update('$done of $total faces');
      }
      // Your profile's fingerprints were the old kind too.
      final pid = profile.personId;
      if (pid != null) {
        await profileFromPerson(pid);
      } else if (profile.isSet && profile.thumb != null) {
        final again = await _engine!.embedCrops([profile.thumb!]);
        profile = FaceProfile(faces: [?again.first], thumb: profile.thumb, source: profile.source);
        await profile.save(db);
        sharing.groups.refreshMe();
      }
      await db.setSetting(_faceModelKey, faceModelId);
      ScanNotification.update('Grouping faces…');
      await regroup();
    } catch (e, st) {
      debugPrint('Face upgrade failed: $e\n$st');
      error = '$e';
    } finally {
      await ScanNotification.stop();
      running = upgrading = false;
      revision++;
      notifyListeners();
    }
  }

  /// Uses [personId]'s faces from People as your profile: many photos of
  /// you make a better match than a few selfies.
  Future<void> profileFromPerson(int personId) async {
    final faces = [for (final f in await db.allFaces()) if (f.personId == personId) f.embedding];
    final cover = await db.facesOf(personId, limit: 1);
    profile = FaceProfile(
      faces: faces.length > FaceProfile.maxFaces ? faces.sublist(0, FaceProfile.maxFaces) : faces,
      thumb: cover.firstOrNull?.thumb,
      source: FaceSource.people,
      personId: personId,
    );
    await profile.save(db);
    sharing.groups.refreshMe();
    notifyListeners();
  }

  Future<void> clearProfile() async {
    profile = FaceProfile(faces: const []);
    await profile.save(db);
    sharing.groups.refreshMe();
    notifyListeners();
  }

  // ---- Trip groups ----

  /// Who gets which of [assetIds]: the faces in each photo against every
  /// member's profile ([members] includes you as [me]). Photos not scanned
  /// yet are looked at now.
  Future<GroupPlan> planGroupSend(Map<String, List<Float32List>> members, String me, List<String> assetIds,
      {void Function(int done, int total)? onProgress}) async {
    final photos = <String, List<PhotoFace>>{};
    for (final f in await db.facesIn(assetIds)) {
      photos.putIfAbsent(f.assetId, () => []).add(PhotoFace(f.assetId, f.embedding, f.thumb));
    }
    final scanned = await db.scannedAssetIds();
    final todo = [for (final id in assetIds) if (!scanned.contains(id)) id];
    if (todo.isNotEmpty) {
      _engine ??= await FaceEngine.load();
      final tmp = File(p.join((await getTemporaryDirectory()).path, 'group_${DateTime.now().microsecondsSinceEpoch}.jpg'));
      try {
        for (final (i, id) in todo.indexed) {
          onProgress?.call(i, todo.length);
          final asset = await AssetEntity.fromId(id);
          if (asset == null) continue;
          final bytes = await asset.thumbnailDataWithSize(_sizeFor(asset), quality: 90);
          if (bytes == null) continue;
          await tmp.writeAsBytes(bytes, flush: true);
          try {
            photos[id] = [for (final f in await _engine!.analyze(tmp.path)) PhotoFace(id, f.embedding, f.thumb)];
          } catch (e) {
            debugPrint('Skipping $id: $e');
          }
        }
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    }
    final t = thresholds;
    final input = GroupPlanInput(
      {for (final e in members.entries) if (e.value.isNotEmpty) e.key: e.value},
      me,
      assetIds,
      photos,
      t.assign,
      t.assign - _unsureRange,
    );
    return Isolate.run(() => planGroup(input));
  }

  /// "Find my photos": who the biggest face in [selfie] is, if they look
  /// enough like someone here, and the photos they're in (newest first).
  Future<({int personId, String? name, List<String> photos})?> findInSelfie(
      File selfie, {int? tripId}) async {
    _engine ??= await FaceEngine.load();
    final faces = await _engine!.analyze(selfie.path);
    if (faces.isEmpty) return null;
    final face = faces.reduce((a, b) => a.width * a.height >= b.width * b.height ? a : b);
    final people = {for (final p in await db.people(tripId: tripId)) p.id: p};
    final byPerson = <int, List<Float32List>>{};
    for (final f in await db.allFaces()) {
      if (f.personId != null && people.containsKey(f.personId)) {
        byPerson.putIfAbsent(f.personId!, () => []).add(f.embedding);
      }
    }
    if (byPerson.isEmpty) return null;
    final input = SuggestInput(byPerson, {0: face.embedding}, thresholds.assign);
    final best = await Isolate.run(() => suggestMatches(input));
    if (best.isEmpty) return null;
    final id = best.first.personId;
    final photos = await db.photosOf(id, tripId: tripId);
    return (personId: id, name: people[id]!.name, photos: [for (final p in photos) p.assetId]);
  }

  /// A selfie from a "Find my photos" link: open (or reopen) a gallery of
  /// that person's photos.
  Future<({WebShare share, String name})?> _answerSelfie(FindLink link, File selfie) async {
    final found = await findInSelfie(selfie, tripId: link.tripId);
    if (found == null || found.photos.isEmpty) return null;
    final name = found.name ?? 'you';
    final open = sharing.server.shares[link.galleries[found.personId]];
    if (open != null) return (share: open, name: name);
    final title = found.name == null ? 'Your photos' : "${found.name}'s photos";
    final share = await sharing.openWebShare(
        link.tripId == null ? title : '$title · ${link.title}', found.photos);
    link.galleries[found.personId] = share.id;
    return (share: share, name: name);
  }

  Duration? get eta {
    final start = _startedAt;
    final work = done - skipped;
    if (start == null || work < 5) return null;
    final perPhoto = DateTime.now().difference(start) ~/ work;
    return perPhoto * (total - done);
  }

  void cancel() => _cancel = true;

  /// The last scan was stopped before the end.
  bool get stopped => _cancel;

  /// Scans [album], or only its photos taken within [dates].
  Future<void> scan(AssetPathEntity album, {DaySpan? dates}) async {
    if (running) return;
    final base = album.isAll ? 'All photos' : album.name;
    if (dates != null) album = await Gallery.inRange(album, dates);
    final source = album;
    // A date-limited scan is its own trip.
    final key = dates == null
        ? album.id
        : '${album.id}@${dates.start.millisecondsSinceEpoch}-${dates.end.millisecondsSinceEpoch}';
    await _scanSource(
      name: dates == null ? base : '$base · ${formatSpan(dates)}',
      key: key,
      total: await source.assetCountAsync,
      page: (start, end) => source.getAssetListRange(start: start, end: end),
    );
  }

  /// Scans every photo inside a folder on the phone (and its subfolders),
  /// e.g. one picked with the folder picker. [folder] is a path like
  /// `/storage/emulated/0/DCIM/Trip` or a relative one like `DCIM/Trip`.
  Future<int> scanFolder(String folder) async {
    if (running) return 0;
    final relative = folderToRelative(folder);
    final all = await Gallery.allPhotos();
    if (all == null) return 0;
    final count = await all.assetCountAsync;
    final matches = <AssetEntity>[];
    for (var i = 0; i < count; i += 500) {
      for (final a in await all.getAssetListRange(start: i, end: (i + 500).clamp(0, count))) {
        final path = (a.relativePath ?? '').toLowerCase();
        if (path.startsWith(relative.toLowerCase())) matches.add(a);
      }
    }
    if (matches.isEmpty) return 0;
    final name = relative.split('/').where((part) => part.isNotEmpty).lastOrNull ?? 'Folder';
    unawaited(_scanSource(
      name: name,
      key: 'folder:${relative.toLowerCase()}',
      total: matches.length,
      page: (start, end) async => matches.sublist(start, end),
    ));
    return matches.length;
  }

  Future<void> _scanSource({
    required String name,
    required String key,
    required int total,
    required Future<List<AssetEntity>> Function(int start, int end) page,
  }) async {
    if (running) return;
    running = true;
    _cancel = false;
    error = null;
    albumName = name;
    done = skipped = facesFound = 0;
    peopleFound = null;
    recentFaces.clear();
    preview = null;
    peopleSoFar = 0;
    _liveSums.clear();
    _liveCounts.clear();
    this.total = total;
    tripId = await db.tripForAlbum(key, name);
    notifyListeners();
    await ScanNotification.start('Starting…');

    final dir = (await getTemporaryDirectory()).path;
    // One scan copy per photo in flight.
    final tmps = [for (var i = 0; i < _inFlight; i++) File(p.join(dir, 'scan_$i.jpg'))];
    try {
      _engine ??= await FaceEngine.load();
      final scanned = await db.scannedAssetIds();
      final tagged = await db.taggedAssetIds(tagVersion);
      _startedAt = DateTime.now();

      for (var start = 0; start < total && !_cancel; start += _pageSize) {
        final assets = await page(start, (start + _pageSize).clamp(0, total));
        await db.addToTrip(tripId!, assets.map((a) => a.id));
        // A few photos at once: while one waits on the photo library,
        // another is in face detection and a third in the labeller.
        var next = 0;
        Future<void> lane(File tmp) async {
          while (!_cancel && next < assets.length) {
            final asset = assets[next++];
            if (tagged.contains(asset.id)) {
              skipped++;
            } else {
              // Already-scanned photos only need categorising, not faces.
              await _scanOne(asset, tmp, facesDone: scanned.contains(asset.id));
            }
            final facesBefore = facesFound;
            done++;
            _celebrate(facesBefore);
            // Every photo when scanning (live preview), less often when skipping.
            if (!tagged.contains(asset.id) || done % 20 == 0) notifyListeners();
            if (done % 5 == 0) {
              ScanNotification.update('$done of $total photos · $facesFound faces');
            }
          }
        }

        await Future.wait([for (final t in tmps) lane(t)]);
      }
      final took = DateTime.now().difference(_startedAt!);
      final work = done - skipped;
      // Kept in release builds: the one line that tells how fast scanning is.
      debugPrint('Scan done: $work photos scanned ($skipped skipped), $facesFound faces '
          'in ${took.inSeconds}s'
          '${work > 0 ? ' = ${(took.inMilliseconds / work).round()} ms/photo' : ''}');
      ScanNotification.update('Grouping faces…');
      await regroup();
      peopleFound = (await db.people(tripId: tripId)).length;
    } catch (e, st) {
      debugPrint('Scan failed: $e\n$st');
      error = '$e';
    } finally {
      for (final tmp in tmps) {
        if (await tmp.exists()) await tmp.delete();
      }
      await ScanNotification.stop();
      running = false;
      if (_receivedPending) {
        _receivedPending = false;
        unawaited(scanReceived());
      }
      _startedAt = null;
      revision++;
      notifyListeners();
      unawaited(guessGenders());
    }
  }

  /// The scan copy's size: the long side [_scanSize], same shape as the photo.
  static ThumbnailSize _sizeFor(AssetEntity asset) {
    final w = asset.width, h = asset.height;
    return (w <= 0 || h <= 0)
        ? const ThumbnailSize.square(_scanSize)
        : w >= h
            ? ThumbnailSize(_scanSize, _scanSize * h ~/ w)
            : ThumbnailSize(_scanSize * w ~/ h, _scanSize);
  }

  Future<void> _scanOne(AssetEntity asset, File tmp,
      {required bool facesDone}) async {
    try {
      // A downscaled, already-rotated JPEG from the photo library. The
      // original photo is never touched.
      final bytes = await asset.thumbnailDataWithSize(_sizeFor(asset), quality: 90);
      if (bytes == null) return;
      // Read back by this app only, straight away: no need to force it to disk.
      await tmp.writeAsBytes(bytes);
      // Things that don't depend on the faces start now, alongside them.
      // Each settles to "unknown" on failure: nothing waits on them if the
      // faces fail first.
      final labels = _engine!.labels(tmp.path).catchError((Object _) => <String>[]);
      final where = asset.latlngAsync().then<LatLng?>((v) => v, onError: (Object _) => null);
      final hash = _hash(asset).catchError((Object _) => null);
      final faces = facesDone ? const <NewFace>[] : await _engine!.analyze(tmp.path);
      // The live preview changes in one go, so with several photos in
      // flight one photo never shows another's face boxes.
      final shown = asset.orientatedSize;
      preview = bytes;
      previewAspect = shown.width > 0 && shown.height > 0 ? shown.width / shown.height : 1;
      previewFaces = [for (final f in faces) Rect.fromLTWH(f.left, f.top, f.width, f.height)];
      previewThumbs = [for (final f in faces) f.thumb];
      previewId++;
      if (!facesDone) {
        facesFound += faces.length;
        for (final f in faces) {
          _countLive(f.embedding);
        }
        for (final f in faces) {
          recentFaces.insert(0, f.thumb);
        }
        if (recentFaces.length > _recentLimit) {
          recentFaces.removeRange(_recentLimit, recentFaces.length);
        }
        await db.savePhoto(asset.id, faces, takenAt: asset.createDateTime);
      }
      await _tag(asset, labels: await labels, where: await where, hash: await hash);
    } catch (e) {
      // One broken photo shouldn't stop a 5,000-photo scan.
      debugPrint('Skipping ${asset.id}: $e');
    }
  }

  /// Quick leader clustering, only for the "≈ N people so far" estimate.
  void _countLive(Float32List v) {
    final limit = thresholds.cluster;
    var best = -1;
    var bestSim = limit;
    for (var c = 0; c < _liveSums.length; c++) {
      final sum = _liveSums[c];
      var dot = 0.0, norm = 0.0;
      for (var i = 0; i < v.length; i++) {
        dot += sum[i] * v[i];
        norm += sum[i] * sum[i];
      }
      final sim = norm == 0 ? 0 : dot / math.sqrt(norm);
      if (sim >= bestSim) {
        bestSim = sim.toDouble();
        best = c;
      }
    }
    if (best < 0) {
      _liveSums.add(Float32List.fromList(v));
      _liveCounts.add(1);
      return;
    }
    final sum = _liveSums[best];
    for (var i = 0; i < v.length; i++) {
      sum[i] += v[i];
    }
    if (++_liveCounts[best] == 2) peopleSoFar++;
  }

  void _celebrate(int facesBefore) {
    if (_photoMilestones.contains(done)) {
      _milestones.add('${_thousands(done)} photos scanned!');
    }
    for (final m in _faceMilestones) {
      if (facesBefore < m && facesFound >= m) {
        _milestones.add('${_thousands(m)} faces found!');
      }
    }
  }

  static String _thousands(int n) => n >= 1000
      ? '${n ~/ 1000},${(n % 1000).toString().padLeft(3, '0')}'
      : '$n';

  /// Works out the photo's categories (selfie, beach, screenshot, …).
  Future<void> _tag(AssetEntity asset,
      {required List<String> labels, required LatLng? where, required int? hash}) async {
    final stats = await db.faceStats(asset.id);
    final ll = where;
    final hasLocation = ll != null && (ll.latitude != 0 || ll.longitude != 0);
    final size = asset.orientatedSize;
    await db.savePhotoMeta(
      asset.id,
      hash: hash,
      lat: hasLocation ? ll.latitude : null,
      lng: hasLocation ? ll.longitude : null,
      quality: photoQuality(
        faceCount: stats.count,
        avgSharpness: stats.avgSharpness,
        minEyesOpen: stats.minEyes,
        maxSmile: stats.maxSmile,
      ),
    );
    final tags = tagsFor(PhotoFacts(
      faceCount: stats.count,
      maxFaceArea: stats.maxArea,
      minFaceSharpness: stats.minSharpness,
      width: size.width.round(),
      height: size.height.round(),
      folder: asset.relativePath ?? '',
      title: asset.title ?? '',
      hasLocation: hasLocation,
      labels: labels,
      minEyesOpen: stats.minEyes,
      maxSmile: stats.maxSmile,
      maxYaw: stats.maxYaw,
    ));
    await db.saveTags(asset.id, tags, tagVersion);
  }

  /// Duplicate fingerprint from a tiny thumbnail (cheap to decode). Uses
  /// Android's stored thumbnail when it can: the photo library plugin would
  /// decode the whole photo again just for these 72 pixels.
  Future<int?> _hash(AssetEntity asset) async {
    final stored = await FastThumb.pixels(asset.id, 48, video: asset.type == AssetType.video);
    if (stored != null) {
      final tiny = img.copyResize(
          img.Image.fromBytes(
              width: stored.width, height: stored.height, bytes: stored.rgba.buffer, numChannels: 4),
          width: 9,
          height: 8,
          interpolation: img.Interpolation.average);
      return differenceHash([
        for (var y = 0; y < 8; y++)
          for (var x = 0; x < 9; x++) tiny.getPixel(x, y).luminance.toInt(),
      ]);
    }
    final bytes = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(48), quality: 80);
    if (bytes == null) return null;
    final small = img.decodeImage(bytes);
    if (small == null) return null;
    final tiny = img.copyResize(small, width: 9, height: 8,
        interpolation: img.Interpolation.average);
    return differenceHash([
      for (var y = 0; y < 8; y++)
        for (var x = 0; x < 9; x++) tiny.getPixel(x, y).luminance.toInt(),
    ]);
  }

  /// Groups every face that isn't in a person yet.
  Future<void> regroup({bool fromScratch = false}) async {
    if (fromScratch) await db.resetAutoGroups();
    final input = await _groupingInput(thresholds, fromScratch: false);
    final result = await Isolate.run(() => groupFaces(input));
    await db.applyGrouping(result.assignToExisting, result.newGroups);
    changed();
  }

  /// How many people regrouping from scratch at [value] would give.
  Future<int> previewStrictness(double value) async {
    final input = await _groupingInput(
        GroupingThresholds.fromStrictness(value),
        fromScratch: true);
    return Isolate.run(() => previewGroupCount(input));
  }

  Future<void> setStrictness(double value) async {
    strictness = value;
    await db.setSetting(_strictnessKey, '$value');
    await regroup(fromScratch: true);
  }

  Future<GroupingInput> _groupingInput(GroupingThresholds t,
      {required bool fromScratch}) async {
    final faces = await db.allFaces();
    final named = fromScratch ? await db.namedPersonIds() : const <int>{};
    // In a from-scratch preview, only named people and hand-placed faces
    // keep their person; everything else is regrouped.
    int? keep(FaceRecord f) => !fromScratch ||
            f.locked ||
            (f.personId != null && named.contains(f.personId))
        ? f.personId
        : null;
    return GroupingInput(
      [for (final f in faces) f.id],
      [for (final f in faces) f.embedding],
      [for (final f in faces) keep(f)],
      [for (final f in faces) f.locked],
      t,
    );
  }

  /// Everything waiting for a decision: unnamed groups first, then lone
  /// faces that resemble someone already named.
  Future<List<ReviewItem>> reviewQueue() async {
    final items = <ReviewItem>[];
    final people = {for (final p in await db.people()) p.id: p};
    final allFaces = await db.allFaces();

    // 1. "Same person?" pairs — one answer fixes many photos at once.
    final everyone = <int, List<Float32List>>{};
    for (final f in allFaces) {
      if (f.personId != null && people.containsKey(f.personId)) {
        everyone.putIfAbsent(f.personId!, () => []).add(f.embedding);
      }
    }
    final mergeInput = MergeInput(everyone, await db.dismissedPairs(),
        thresholds.merge - _mergeHintRange, thresholds.merge);
    final merges = await Isolate.run(() => suggestMerges(mergeInput));
    for (final m in merges.take(_maxMergeHints)) {
      final a = people[m.a]!, b = people[m.b]!;
      items.add(MergeReview(a, b, await db.facesOf(a.id, limit: 3),
          await db.facesOf(b.id, limit: 3), m.similarity));
    }

    // 2. Unnamed groups, biggest first.
    final groups = await db.unreviewedGroups()
      ..sort((x, y) => y.photoCount.compareTo(x.photoCount));
    for (final g in groups) {
      items.add(GroupReview(g, await db.facesOf(g.id, limit: 6)));
    }

    final named = await db.namedPersonIds();
    if (named.isEmpty) return items;
    final byPerson = <int, List<Float32List>>{};
    for (final f in allFaces) {
      if (f.personId != null && named.contains(f.personId)) {
        byPerson.putIfAbsent(f.personId!, () => []).add(f.embedding);
      }
    }
    final unsorted = await db.unsortedFaces();
    final thumbs = {for (final u in unsorted) u.id: u.thumb};
    final input = SuggestInput(
        byPerson, {for (final u in unsorted) u.id: u.embedding}, _suggestMin);
    // 3. Lone faces, least certain first: those answers teach the most.
    final matches = await Isolate.run(() => suggestMatches(input))
      ..sort((x, y) => (x.similarity - _unsure).abs().compareTo((y.similarity - _unsure).abs()));
    // A match this strong isn't a question: add it to that person instead.
    // (Happens to faces left alone before their person was named.)
    final sure = <int, int>{};
    for (final m in matches) {
      final person = people[m.personId];
      if (person == null) continue;
      if (m.similarity >= _autoAccept) {
        sure[m.faceId] = m.personId;
        continue;
      }
      items.add(FaceReview(m.faceId, thumbs[m.faceId]!, person, m.similarity));
    }
    if (sure.isNotEmpty) {
      await db.applyGrouping(sure, const []);
      changed();
    }
    return items;
  }

  bool _guessingGenders = false;

  /// Guesses the gender of people who don't have a guess yet (new people,
  /// or ones that just gained faces), from their clearest faces.
  Future<void> guessGenders() async {
    if (_guessingGenders || running) return;
    _guessingGenders = true;
    try {
      final ids = await db.peopleWithoutGenderGuess();
      if (ids.isEmpty) return;
      final faces = {
        for (final id in ids) id: [for (final f in await db.facesOf(id, limit: _genderFaces)) f.thumb],
      };
      await db.saveGenderGuesses(await guessFemaleChance(faces));
      revision++;
      notifyListeners();
    } catch (e) {
      debugPrint('Gender guess failed: $e');
    } finally {
      _guessingGenders = false;
    }
  }

  /// Call after any manual edit (rename, merge, remove) so screens refresh.
  void changed() {
    revision++;
    notifyListeners();
  }
}

/// `DCIM/Trip/` from `/storage/emulated/0/DCIM/Trip` (or a picker's
/// `primary:DCIM/Trip`), which is how the gallery names folders.
String folderToRelative(String folder) {
  var f = folder.replaceAll('\\', '/');
  final colon = f.indexOf(':');
  if (colon >= 0 && !f.startsWith('/')) f = f.substring(colon + 1);
  final m = RegExp(r'^/storage/(emulated/\d+|[^/]+)/').firstMatch(f);
  if (m != null) f = f.substring(m.end);
  f = f.replaceAll(RegExp(r'^/+'), '');
  return f.endsWith('/') || f.isEmpty ? f : '$f/';
}
