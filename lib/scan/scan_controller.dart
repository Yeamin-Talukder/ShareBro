import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui show ImageByteFormat, instantiateImageCodec;
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
import '../face/accel.dart';
import '../face/clustering.dart';
import '../face/face_engine.dart';
import '../face/gender.dart';
import '../face/tags.dart';
import '../platform/device.dart';
import '../share/receive.dart' show receivedAlbum;
import '../share/send_center.dart';
import '../share/server.dart' show FindLink, WebShare;
import 'background.dart';
import 'desktop_folders.dart';
import 'scan_item.dart';
import '../platform/desktop_library.dart';
import '../data/people_sync.dart';
import '../share/people_link.dart';
import '../share/protocol.dart' show LsDevice, LsDeviceType, LsInfo;
import '../platform/app_dirs.dart';
import '../share/scan_helper.dart';

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

/// Desktop: photos are decoded for scanning at a long side of at least
/// this (by halves, quarters or eighths; see [DesktopScanItem.decodePixels]).
/// The face finder looks at 640 px and faces are cropped to 112 px.
const _desktopDecodeAtLeast = 1000;

/// Desktop scans make a live-view picture at most this often. Making one
/// for every photo took about a third of the face workers' time
/// (tool/scan_bench.dart), and the screen can't show 15 a second anyway.
const _desktopPreviewEvery = Duration(milliseconds: 250);

/// Scanned photos are saved together, this many at a time (or every
/// couple of seconds), instead of each step of each photo on its own.
const _saveEvery = 48;
const _saveAfter = Duration(seconds: 2);

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
const _faceChipKey = 'face_chip';

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

/// Where a phone scan lane finds faces: ML Kit here, the graphics chip
/// here, or your computer.
enum _Via { here, gpu, computer }

/// Runs scans and grouping, and tells the UI what's happening.
class ScanController extends ChangeNotifier {
  ScanController(this.db);

  final AppDb db;
  FaceEngine? _engine;

  /// How faces are being found, for logs: "2 workers, graphics chip".
  String get engineSummary {
    final e = _engine;
    if (e == null) return 'not loaded';
    if (!Device.desktop) {
      return 'ML Kit on $_inFlight lanes'
          '${e.gpuLanes > 0 ? ', graphics chip on ${e.gpuLanes}' : ''}'
          '${helper != null ? ', computer on $_helperLanes' : ''}';
    }
    return '${e.parallel} worker${e.parallel == 1 ? '' : 's'}${e.onGpu ? ', graphics chip' : ''}';
  }

  /// The chip [_engine] was opened for.
  AccelChoice? _engineChip;

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

  /// When a desktop photo last asked for a live-view picture.
  DateTime _lastPreviewAsked = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// Which chip turns faces into fingerprints: the fastest that works on
  /// this phone, or the one picked in Settings.
  AccelChoice faceChip = AccelChoice.auto;

  Timer? _autoScanTimer;
  AppLifecycleListener? _lifecycle;

  /// Sending to friends' phones and web galleries (LocalSend protocol).
  late final SendCenter sharing;

  /// Swapping who's who (names and face fingerprints, never photos) with
  /// your other devices.
  late final PeopleSyncHub peopleSync;

  /// Your face, set up once in Profile.
  FaceProfile profile = FaceProfile(faces: const []);

  // ---- Scanning with your computer's help ----

  /// Desktop: scanning for your phones.
  ScanHelperHub? scanHelper;

  /// Phone: the computer paired to help (its fingerprint and name, and the
  /// key it gave us), and whether to use it.
  String? helperPc, helperPcName;
  String? _helperKey;
  bool helperOn = true;

  /// Phone: days the computer may remember face results (0 is off; see
  /// [scanHelpKeepChoices]). The computer follows this phone's choice.
  int helperKeepDays = 0;

  /// Phone, while scanning: the computer helping, and photos it scanned.
  ScanHelperClient? helper;
  int helperPhotos = 0;

  /// Phone: photos whose faces the graphics chip found this scan.
  int gpuPhotos = 0;

  static const _helperPcKey = 'scan_helper_pc';
  static const _helperNameKey = 'scan_helper_name';
  static const _helperKeyKey = 'scan_helper_key';
  static const _helperOnKey = 'scan_helper_on';
  static const _helperKeepKey = 'scan_helper_keep';
  static const _helperIpKey = 'scan_helper_ip';
  static const _helperPortKey = 'scan_helper_port';

  /// Desktop: the server and discovery are kept open (findable on this
  /// Wi‑Fi) while helping phones is allowed.
  bool _helperListening = false;

  Future<void> _syncHelperListening() async {
    final want = Device.desktop && (scanHelper?.allowed ?? false);
    if (want && !_helperListening) {
      _helperListening = true;
      await sharing.open();
    } else if (!want && _helperListening) {
      _helperListening = false;
      await sharing.close();
    }
  }

  /// Phone: remembers where the computer was, to try it there when it
  /// isn't heard announcing itself.
  Future<void> _saveHelperAddress(LsDevice pc) async {
    await db.setSetting(_helperIpKey, pc.ip);
    await db.setSetting(_helperPortKey, '${pc.info.port}');
  }

  /// The paired computer at the address it had last time.
  Future<LsDevice?> _lastKnownHelper() async {
    final fp = helperPc;
    final ip = await db.setting(_helperIpKey);
    final port = int.tryParse(await db.setting(_helperPortKey) ?? '');
    if (fp == null || ip == null || ip.isEmpty || port == null) return null;
    return LsDevice(
      info: LsInfo(
        alias: helperPcName ?? 'Computer',
        fingerprint: fp,
        deviceModel: 'ShareBro',
        deviceType: LsDeviceType.desktop,
        port: port,
        protocol: 'https',
      ),
      ip: ip,
      lastSeen: DateTime.now(),
    );
  }

  /// Photo lanes the computer takes while it helps (the phone keeps its
  /// own [_inFlight]).
  static const _helperLanes = 4;

  Future<void> _loadHelper() async {
    helperPc = await db.setting(_helperPcKey);
    helperPcName = await db.setting(_helperNameKey);
    _helperKey = await db.setting(_helperKeyKey);
    helperOn = await db.setting(_helperOnKey) != '0';
    final keep = int.tryParse(await db.setting(_helperKeepKey) ?? '') ?? 0;
    helperKeepDays = scanHelpKeepChoices.contains(keep) ? keep : 0;
    if (helperPc != null && helperPc!.isEmpty) helperPc = null;
  }

  /// ShareBro computers on this Wi‑Fi that could help.
  List<LsDevice> get helperCandidates => [
        for (final d in sharing.discovery.devices)
          if (d.info.deviceModel == 'ShareBro' &&
              d.info.deviceType == LsDeviceType.desktop &&
              d.fingerprint != sharing.identity.fingerprint)
            d,
      ];

  /// The paired computer, if it's on this Wi‑Fi now.
  LsDevice? get helperNearby => helperCandidates.where((d) => d.fingerprint == helperPc).firstOrNull;

  /// Phone: pairs [pc] (it asks there, showing [code]) and remembers it.
  Future<void> pairHelper(LsDevice pc, String code) async {
    String? key;
    final client = await ScanHelperClient.connect(pc,
        me: sharing.identity, faceModel: faceModelId, code: code, onKey: (k) => key = k);
    client.close();
    helperPc = pc.fingerprint;
    helperPcName = client.alias;
    _helperKey = key ?? _helperKey;
    await _saveHelperAddress(pc);
    helperOn = true;
    await db.setSetting(_helperPcKey, pc.fingerprint);
    await db.setSetting(_helperNameKey, client.alias);
    if (_helperKey != null) await db.setSetting(_helperKeyKey, _helperKey!);
    await db.setSetting(_helperOnKey, '1');
    notifyListeners();
    // Paired during a scan: it starts helping with this one.
    if (running) unawaited(joinHelperMidScan());
  }

  Future<void> forgetHelper() async {
    helperPc = helperPcName = _helperKey = null;
    await db.setSetting(_helperPcKey, '');
    await db.setSetting(_helperNameKey, '');
    await db.setSetting(_helperKeyKey, '');
    notifyListeners();
  }

  Future<void> setHelperOn(bool on) async {
    helperOn = on;
    notifyListeners();
    await db.setSetting(_helperOnKey, on ? '1' : '0');
    if (!running) return;
    if (on) {
      // Turned on mid-scan: the computer joins this scan now.
      unawaited(joinHelperMidScan());
    } else if (helper != null) {
      // Turned off mid-scan: the phone carries on alone.
      helper!.close();
      helper = null;
      notifyListeners();
    }
  }

  /// While a page of a scan runs: adds the computer's lanes to it.
  void Function()? _joinComputer;

  bool _searchingHelper = false;

  /// The computer wasn't heard and isn't at its last address (a phone
  /// sharing its own hotspot is on a different network, and some hotspots
  /// block multicast): knock on every address of every network this phone
  /// is on, in the background, and bring it into the running scan as soon
  /// as it answers.
  void _searchForHelper() {
    if (_searchingHelper || Device.desktop || helperPc == null) return;
    _searchingHelper = true;
    unawaited(() async {
      try {
        await sharing.discovery.scanSubnet();
        final pc = helperNearby;
        if (pc != null) {
          await _saveHelperAddress(pc);
          if (running && helper == null) {
            _lastJoinTry = DateTime.fromMillisecondsSinceEpoch(0);
            await joinHelperMidScan();
          }
        }
      } catch (e) {
        debugPrint('Looking for the computer failed: $e');
      } finally {
        _searchingHelper = false;
      }
    }());
  }
  bool _joining = false;

  /// Looking for the computer to join the running scan.
  bool get joiningHelper => _joining;
  DateTime _lastJoinTry = DateTime.fromMillisecondsSinceEpoch(0);
  static const _rejoinEvery = Duration(seconds: 30);

  /// Phone, during a scan: connects to the paired computer and lets it
  /// start helping straight away (it was just turned on or paired, or it
  /// wasn't there when the scan started).
  Future<void> joinHelperMidScan() async {
    if (Device.desktop || !running || helper != null || _joining) return;
    _joining = true;
    notifyListeners();
    try {
      final h = await _connectHelper();
      if (h == null) return;
      if (!running || !helperOn || helper != null) {
        h.close();
        return;
      }
      helper = h;
      debugPrint('Scan helper joined mid-scan: ${h.alias}');
      _joinComputer?.call();
      notifyListeners();
    } finally {
      _joining = false;
      _lastJoinTry = DateTime.now();
      notifyListeners();
    }
  }

  /// How long the computer may remember face results. Takes effect on the
  /// computer with the next photo it scans for this phone (0 deletes what
  /// it remembers then).
  Future<void> setHelperKeepDays(int days) async {
    if (!scanHelpKeepChoices.contains(days)) return;
    helperKeepDays = days;
    notifyListeners();
    await db.setSetting(_helperKeepKey, '$days');
  }

  /// Phone, at the start of a scan: connect to the paired computer if it's
  /// here. Quietly null if it isn't (the phone scans alone).
  Future<ScanHelperClient?> _connectHelper() async {
    if (Device.desktop || !helperOn || helperPc == null || _helperKey == null) return null;
    // Listen and announce for a moment: the computer answers when it hears
    // us. If it doesn't, try where it was last time.
    await sharing.open();
    try {
      var pc = helperNearby;
      for (var i = 0; i < 15 && pc == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        pc = helperNearby;
      }
      final heard = pc != null;
      pc ??= await _lastKnownHelper();
      if (pc == null) {
        _searchForHelper();
        return null;
      }
      final ScanHelperClient client;
      try {
        client = await ScanHelperClient.connect(pc,
            me: sharing.identity, faceModel: faceModelId, key: _helperKey, keepDays: helperKeepDays);
      } catch (_) {
        // Not at its last address (a different network, say this phone's
        // own hotspot): look for it on every network we're on.
        if (!heard) _searchForHelper();
        rethrow;
      }
      if (heard) await _saveHelperAddress(pc);
      // The computer shows how the whole scan is going, and follows this
      // phone's setting for remembering results.
      client.progress = () => ScanHelpProgress(
            done: done,
            total: total,
            rate: photosPerSecond ?? 0,
            keepDays: helperKeepDays,
            album: albumName,
          );
      return client;
    } catch (e) {
      debugPrint('Scan helper not used: $e');
      return null;
    } finally {
      await sharing.close();
    }
  }

  /// Desktop: the faces in a phone's scan copy (an upright JPEG, the same
  /// 1600 px copy the phone would scan), found as the phone would.
  Future<List<NewFace>> facesForPhone(Uint8List jpeg) async {
    await _readyEngine();
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final w = image.width, h = image.height;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return const [];
    final scan = await _engine!.analyzeRgba(
        TransferableTypedData.fromList([data.buffer.asUint8List()]), w, h,
        minFace: minFacePx);
    return scan?.faces ?? const [];
  }

  Future<void> load() async {
    sharing = await SendCenter.create(db);
    peopleSync = PeopleSyncHub(sharing.identity, build: peoplePackage, take: takePeople);
    sharing.server.people = peopleSync;
    await _loadHelper();
    if (Device.desktop) {
      final hub = ScanHelperHub(
        readSetting: db.setting,
        writeSetting: db.setSetting,
        faceModel: faceModelId,
        analyze: facesForPhone,
        alias: () => sharing.identity.alias,
        resultsRoot: appDataDir,
      );
      await hub.load();
      scanHelper = hub;
      sharing.server.scanHelper = hub;
      // Findable on this Wi‑Fi while helping is on; not when it's off.
      hub.addListener(() => unawaited(_syncHelperListening()));
      await _syncHelperListening();
    }
    // Photos friends send us get scanned like any other album.
    sharing.receiver.onSaved = (_) => scanReceived();
    sharing.server.onSelfie = _answerSelfie;
    profile = await FaceProfile.load(db);
    sharing.groups.profile = () => profile;
    final s = await db.setting(_strictnessKey);
    strictness = double.tryParse(s ?? '') ?? GroupingThresholds.defaultStrictness;
    autoScanEnabled = (await db.setting(_autoScanKey)) != '0';
    appLock = (await db.setting(_appLockKey)) == '1';
    faceChip = AccelChoice.byName(await db.setting(_faceChipKey));
    if (Device.desktop) {
      // Photos are files in folders: dates come from the scan, and the
      // folders scanned before are checked for new photos.
      desktopTakenAt = db.takenAt;
      unawaited(upgradeFaces());
      _queueAutoScan(const Duration(seconds: 4));
      return;
    }
    if (!Device.photoLibrary) return;
    backfillDates();
    unawaited(backfillLocations());
    unawaited(upgradeFaces());
    _watchForNewPhotos();
  }

  /// What's known about this phone's chips: which work, and how fast.
  Future<AccelState> faceChips() async => AccelState.read(await accelStatePath(), accelStateKey(faceModelId));

  /// Whether the graphics chip can find faces next to ML Kit, and how fast.
  Future<AccelState> gpuFinder() async => AccelState.read(await gpuFinderStatePath(), gpuFinderStateKey());

  /// Takes effect the next time faces are scanned. Asking for one chip by
  /// name gives it a fresh try, even if it failed before.
  Future<void> setFaceChip(AccelChoice choice) async {
    faceChip = choice;
    await db.setSetting(_faceChipKey, choice.name);
    if (choice.only case final chip? when chip != Accel.cpu) {
      final path = await accelStatePath();
      AccelState.read(path, accelStateKey(faceModelId))
        ..forget(chip)
        ..write(path);
    }
    notifyListeners();
  }

  /// Settings › Test the chips again: forgets what the GPU and NPU did, so
  /// the next scan tries them afresh with a newly opened model.
  Future<void> retestChips() async {
    final path = await accelStatePath();
    AccelState.read(path, accelStateKey(faceModelId))
      ..forget(Accel.gpu)
      ..forget(Accel.npu)
      ..write(path);
    // And the graphics-chip face finder.
    final finder = await gpuFinderStatePath();
    AccelState.read(finder, gpuFinderStateKey())
      ..forget(Accel.gpu)
      ..write(finder);
    _engineChip = null;
    notifyListeners();
  }

  /// Opens the face model, or opens it again after the chip was changed in
  /// Settings. The old one finishes what it was handed first.
  Future<void> _readyEngine() {
    if (_engine != null && _engineChip == faceChip) return Future.value();
    // One opening at a time, however many things ask at once.
    return _engineOpening ??= () async {
      final chip = faceChip;
      final old = _engine;
      _engine = await FaceEngine.load(chip: chip);
      _engineChip = chip;
      old?.dispose();
    }()
        .whenComplete(() => _engineOpening = null);
  }

  Future<void>? _engineOpening;

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
    if (!Device.photoLibrary) return;
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
    if (Device.desktop) return _autoScanFolders();
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

  /// Desktop: rescans the first scanned folder that has new photos in it.
  Future<void> _autoScanFolders() async {
    try {
      final scanned = await db.scannedAssetIds();
      for (final trip in await db.trips()) {
        final folder = desktopFolderOf(trip.albumId);
        if (folder == null || !await Directory(folder).exists()) continue;
        final files = await listPhotoFiles(folder);
        if (files.any((f) => !scanned.contains(f))) {
          debugPrint('Auto-scanning ${trip.name}');
          await scanDesktopFolder(folder);
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
      await _readyEngine();
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
      await _readyEngine();
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
      await _readyEngine();
      final tmp = File(p.join((await getTemporaryDirectory()).path, 'group_${DateTime.now().microsecondsSinceEpoch}.jpg'));
      try {
        for (final (i, id) in todo.indexed) {
          onProgress?.call(i, todo.length);
          final asset = await ScanItem.byId(id);
          if (asset == null) continue;
          final bytes = await asset.scanJpeg(_scanSize);
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
    await _readyEngine();
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

  /// Photos scanned a second over the last few seconds (photos skipped as
  /// already done don't count); null until there's enough to tell.
  double? get photosPerSecond {
    final start = _startedAt;
    if (start == null || _rateTimes.length < 3) return null;
    final now = DateTime.now();
    _rateTimes.removeWhere((t) => now.difference(t) > _rateWindow);
    final span = now.difference(start) < _rateWindow ? now.difference(start) : _rateWindow;
    return _rateTimes.length / math.max(1.0, span.inMilliseconds / 1000);
  }

  static const _rateWindow = Duration(seconds: 10);
  final List<DateTime> _rateTimes = [];

  void _rateTick() {
    final now = DateTime.now();
    _rateTimes.add(now);
    if (_rateTimes.length > 400) _rateTimes.removeWhere((t) => now.difference(t) > _rateWindow);
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
      page: (start, end) async => [
        for (final a in await source.getAssetListRange(start: start, end: end)) PhoneScanItem(a),
      ],
    );
  }

  /// Desktop: scans every photo in [folder] and its subfolders. Returns how
  /// many photos it found (0 if none, or a scan is already running).
  Future<int> scanDesktopFolder(String folder) async {
    if (running) return 0;
    final paths = await listPhotoFiles(folder);
    if (paths.isEmpty) return 0;
    unawaited(_scanSource(
      name: p.basename(folder).isEmpty ? folder : p.basename(folder),
      key: desktopFolderKey(folder),
      total: paths.length,
      page: (start, end) async => [for (final path in paths.sublist(start, end)) DesktopScanItem(path)],
    ));
    return paths.length;
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
      page: (start, end) async => [for (final a in matches.sublist(start, end)) PhoneScanItem(a)],
    ));
    return matches.length;
  }

  Future<void> _scanSource({
    required String name,
    required String key,
    required int total,
    required Future<List<ScanItem>> Function(int start, int end) page,
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
    // One scan copy per photo in flight (phones; desktop scans from pixels).
    // Desktop keeps every face worker busy, with one photo decoding ahead.
    await _readyEngine();
    // Phone: your computer takes some lanes when it's here to help.
    helper = await _connectHelper();
    helperPhotos = 0;
    gpuPhotos = 0;
    _speedPhotos = 0;
    _speedMark = null;
    _rateTimes.clear();
    // Phone lanes: ML Kit on the CPU, then the graphics-chip face finder.
    // Each takes the next photo when it's free. The computer's lanes are
    // added while it's connected, even if it joins halfway through.
    final gpuLanes = Device.desktop ? 0 : _engine!.gpuLanes;
    final vias = Device.desktop
        ? List.filled(_engine!.parallel + 1, _Via.here)
        : [
            for (var i = 0; i < _inFlight; i++) _Via.here,
            for (var i = 0; i < gpuLanes; i++) _Via.gpu,
          ];
    final tmps = [for (var i = 0; i < vias.length; i++) File(p.join(dir, 'scan_$i.jpg'))];
    final helperTmps = [for (var i = 0; i < _helperLanes; i++) File(p.join(dir, 'scan_c$i.jpg'))];
    _lastJoinTry = DateTime.now();
    try {
      final scanned = await db.scannedAssetIds();
      final tagged = await db.taggedAssetIds(tagVersion);
      _startedAt = DateTime.now();

      for (var start = 0; start < total && !_cancel; start += _pageSize) {
        final assets = await page(start, (start + _pageSize).clamp(0, total));
        await db.addToTrip(tripId!, assets.map((a) => a.id));
        if (Device.desktop) await _reuseKnownFiles(assets, scanned, tagged);
        // A few photos at once: while one waits on the photo library,
        // another is in face detection and a third in the labeller.
        var next = 0;
        Future<void> lane(File tmp, _Via via) async {
          while (!_cancel && next < assets.length) {
            // The computer's lanes stop when it goes away or is turned
            // off; the phone's carry on with the rest.
            if (via == _Via.computer && helper == null) return;
            final asset = assets[next++];
            if (tagged.contains(asset.id)) {
              skipped++;
            } else {
              // Already-scanned photos only need categorising, not faces.
              await _scanOne(asset, tmp, facesDone: scanned.contains(asset.id), via: via);
            }
            final facesBefore = facesFound;
            done++;
            if (!tagged.contains(asset.id)) {
              _speedTick();
              _rateTick();
            }
            _celebrate(facesBefore);
            // Every photo when scanning (live preview), less often when skipping.
            if (!tagged.contains(asset.id) || done % 20 == 0) notifyListeners();
            if (done % 5 == 0) {
              final rate = photosPerSecond;
              ScanNotification.update('$done of $total photos · $facesFound faces'
                  '${rate == null ? '' : ' · ${formatRate(rate)} photos/s'}');
            }
          }
        }

        final lanes = [for (final (i, t) in tmps.indexed) lane(t, vias[i])];
        var computerLanes = false;
        void addComputerLanes() {
          if (computerLanes || helper == null) return;
          computerLanes = true;
          for (final t in helperTmps) {
            lanes.add(lane(t, _Via.computer));
          }
        }

        addComputerLanes();
        // A computer that connects during this page starts helping on it.
        _joinComputer = addComputerLanes;
        for (var waited = 0; waited < lanes.length;) {
          final upTo = lanes.length;
          await Future.wait(lanes.sublist(waited, upTo));
          waited = upTo;
        }
        _joinComputer = null;
        await _save();
        // Not helping yet (it wasn't there, or it dropped out)? Look for it
        // again now and then: it may have come onto the Wi‑Fi since.
        if (helper == null && DateTime.now().difference(_lastJoinTry) > _rejoinEvery) {
          unawaited(joinHelperMidScan());
        }
      }
      await _save();
      final took = DateTime.now().difference(_startedAt!);
      final work = done - skipped;
      // Kept in release builds: the one line that tells how fast scanning is.
      debugPrint('Scan done ($engineSummary): $work photos scanned ($skipped skipped), $facesFound faces '
          'in ${took.inSeconds}s'
          '${work > 0 ? ' = ${(took.inMilliseconds / work).round()} ms/photo' : ''}'
          '${gpuPhotos > 0 ? ', $gpuPhotos by the graphics chip' : ''}'
          '${helperPhotos > 0 ? ', $helperPhotos by the computer' : ''}');
      ScanNotification.update('Grouping faces…');
      await regroup();
      peopleFound = (await db.people(tripId: tripId)).length;
    } catch (e, st) {
      debugPrint('Scan failed: $e\n$st');
      error = '$e';
    } finally {
      // Whatever was scanned before a stop or an error is kept.
      try {
        await _save();
      } catch (e) {
        debugPrint('Saving scanned photos failed: $e');
      }
      for (final tmp in [...tmps, ...helperTmps]) {
        if (await tmp.exists()) await tmp.delete();
      }
      _joinComputer = null;
      helper?.close();
      helper = null;
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

  /// Every so many photos, how fast scanning goes and who found the faces:
  /// one line in the log (kept in release builds), for measuring.
  void _speedTick() {
    final now = DateTime.now();
    final mark = _speedMark ??= (now, 0, 0, 0);
    _speedPhotos++;
    if (_speedPhotos - mark.$2 < _speedEvery) return;
    final ms = now.difference(mark.$1).inMilliseconds / (_speedPhotos - mark.$2);
    debugPrint('Scan speed: ${ms.round()} ms/photo over the last ${_speedPhotos - mark.$2} '
        '(graphics chip ${gpuPhotos - mark.$3}, computer ${helperPhotos - mark.$4}; $engineSummary)');
    _speedMark = (now, _speedPhotos, gpuPhotos, helperPhotos);
  }

  static const _speedEvery = 200;
  int _speedPhotos = 0;
  (DateTime, int, int, int)? _speedMark;

  Future<void> _scanOne(ScanItem asset, File tmp,
      {required bool facesDone, _Via via = _Via.here}) async {
    try {
      final found = asset is DesktopScanItem && Device.desktop
          ? await _readDesktop(asset, facesDone: facesDone)
          : await _readPhone(asset, tmp, facesDone: facesDone, via: via);
      if (found == null) return;
      final (faces, labels, where, hash, bytes) = found;
      // The live preview changes in one go, so with several photos in
      // flight one photo never shows another's face boxes.
      final shown = asset.size;
      if (bytes != null) {
        preview = bytes;
        previewAspect = shown.width > 0 && shown.height > 0 ? shown.width / shown.height : 1;
        previewFaces = [for (final f in faces) Rect.fromLTWH(f.left, f.top, f.width, f.height)];
        previewThumbs = [for (final f in faces) f.thumb];
        previewId++;
      }
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
      }
      // Faces found just now are counted here; ones from an earlier scan
      // are read back.
      final stats = facesDone ? await db.faceStats(asset.id) : faceStatsOf(faces);
      await _queue(_record(asset,
          faces: facesDone ? null : faces, stats: stats, labels: labels, where: where, hash: hash));
    } catch (e) {
      // One broken photo shouldn't stop a 5,000-photo scan.
      debugPrint('Skipping ${asset.id}: $e');
    }
  }

  /// Phone: a downscaled, already-rotated JPEG from the photo library goes
  /// to ML Kit (which reads files). The original photo is never touched.
  Future<(List<NewFace>, List<String>, LatLng?, int?, Uint8List?)?> _readPhone(ScanItem asset, File tmp,
      {required bool facesDone, _Via via = _Via.here}) async {
    final bytes = await asset.scanJpeg(_scanSize);
    if (bytes == null) return null;
    // Read back by this app only, straight away: no need to force it to disk.
    await tmp.writeAsBytes(bytes);
    // Things that don't depend on the faces start now, alongside them.
    // Each settles to "unknown" on failure: nothing waits on them if the
    // faces fail first.
    final labels = _engine!.labels(tmp.path).catchError((Object _) => <String>[]);
    final where = asset.location();
    final hash = asset.hash().catchError((Object _) => null);
    final faces = facesDone ? const <NewFace>[] : await _phoneFaces(bytes, tmp.path, via: via);
    return (faces, await labels, await where, await hash, bytes);
  }

  /// The faces in a scan copy: from your computer on its lanes while it's
  /// helping, from the graphics chip on its lanes, else (or if either
  /// fails) from ML Kit.
  Future<List<NewFace>> _phoneFaces(Uint8List jpeg, String path, {required _Via via}) async {
    if (via == _Via.gpu) {
      try {
        final faces = await _engine!.analyzeOnGpu(path);
        gpuPhotos++;
        return faces;
      } catch (e) {
        // This photo goes to ML Kit; after a few failures in a row the
        // graphics chip stops for the rest of the scan.
        debugPrint('Graphics-chip face finder skipped a photo: $e');
      }
    }
    final h = helper;
    if (via == _Via.computer && h != null) {
      try {
        final faces = await h.scan(jpeg);
        helperPhotos++;
        return faces;
      } catch (e) {
        // Gone or failing: the phone takes over from here.
        debugPrint('Scan helper stopped helping: $e');
        if (identical(helper, h)) {
          helper = null;
          h.close();
          notifyListeners();
        }
      }
    }
    return _engine!.analyze(path);
  }

  /// Desktop: the file is decoded once, straight to pixels at the size the
  /// face models need, and handed to a face worker, which also makes the
  /// preview and the duplicate fingerprint. No JPEG is written or read.
  Future<(List<NewFace>, List<String>, LatLng?, int?, Uint8List?)?> _readDesktop(DesktopScanItem asset,
      {required bool facesDone}) async {
    final meta = asset.readMeta();
    final decoded = await asset.decodePixels(atLeast: _desktopDecodeAtLeast);
    if (decoded == null) return null;
    final (pixels, w, h) = decoded;
    // The phone skips faces under [minFacePx] on its 1600 px copies; the
    // same faces measure smaller here.
    final full = math.max(asset.size.width, asset.size.height);
    final minFace = minFacePx * math.max(w, h) / math.max(1.0, math.min(_scanSize.toDouble(), full));
    // Only a few live-view pictures a second; photos in between keep the
    // last one on screen.
    final now = DateTime.now();
    final wantPreview = now.difference(_lastPreviewAsked) >= _desktopPreviewEvery;
    if (wantPreview) _lastPreviewAsked = now;
    final scan = await _engine!.analyzeRgba(TransferableTypedData.fromList([pixels]), w, h,
        minFace: minFace, skipFaces: facesDone, preview: wantPreview);
    await meta;
    return (scan?.faces ?? const <NewFace>[], const <String>[], await asset.location(), scan?.hash, scan?.preview);
  }

  /// What gets saved for a photo: its faces (if new), metadata and tags.
  ScannedPhoto _record(ScanItem asset,
      {required List<NewFace>? faces,
      required FaceStats stats,
      required List<String> labels,
      required LatLng? where,
      required int? hash}) {
    final ll = where;
    final hasLocation = ll != null && (ll.latitude != 0 || ll.longitude != 0);
    final size = asset.size;
    return ScannedPhoto(
      assetId: asset.id,
      takenAt: asset.takenAt,
      faces: faces,
      hash: hash,
      lat: hasLocation ? ll.latitude : null,
      lng: hasLocation ? ll.longitude : null,
      quality: photoQuality(
        faceCount: stats.count,
        avgSharpness: stats.avgSharpness,
        minEyesOpen: stats.minEyes,
        maxSmile: stats.maxSmile,
      ),
      tags: tagsFor(PhotoFacts(
        faceCount: stats.count,
        maxFaceArea: stats.maxArea,
        minFaceSharpness: stats.minSharpness,
        width: size.width.round(),
        height: size.height.round(),
        folder: asset.folder,
        title: asset.title,
        hasLocation: hasLocation,
        labels: labels,
        minEyesOpen: stats.minEyes,
        maxSmile: stats.maxSmile,
        maxYaw: stats.maxYaw,
      )),
      fileKey: asset is DesktopScanItem ? asset.fileKey : null,
    );
  }

  final List<ScannedPhoto> _unsaved = [];
  DateTime _savedAt = DateTime.now();
  Future<void> _saving = Future.value();

  /// Keeps [photo] to save with others (see [_saveEvery]).
  Future<void> _queue(ScannedPhoto photo) async {
    _unsaved.add(photo);
    if (_unsaved.length >= _saveEvery || DateTime.now().difference(_savedAt) >= _saveAfter) await _save();
  }

  /// Saves every photo waiting, in one transaction. Saves run one after
  /// another, in order.
  Future<void> _save() {
    if (_unsaved.isEmpty) return _saving;
    final batch = List.of(_unsaved);
    _unsaved.clear();
    _savedAt = DateTime.now();
    return _saving = _saving.then((_) => db.saveScanned(batch, tagVersion));
  }

  /// Desktop, before a page of photos is scanned: an unchanged file that
  /// was scanned before is skipped; one that changed since is scanned
  /// again; and a new path whose file was already scanned somewhere else
  /// (moved, copied or renamed) gets that scan copied instead of redone.
  Future<void> _reuseKnownFiles(List<ScanItem> assets, Set<String> scanned, Set<String> tagged) async {
    final items = assets.whereType<DesktopScanItem>().toList();
    if (items.isEmpty) return;
    final known = await db.fileKeys(items.map((i) => i.id));
    final missing = <String, FileKey>{};
    final fresh = <DesktopScanItem>[];
    await Future.wait([
      for (final item in items)
        () async {
          final saved = known[item.id];
          if (scanned.contains(item.id) && saved != null) {
            // Known file: its size and date say whether it changed, without
            // reading it.
            final FileStat stat;
            try {
              stat = await File(item.id).stat();
            } catch (_) {
              return;
            }
            if (stat.size == saved.size && stat.modified.millisecondsSinceEpoch == saved.modified) {
              item.fileKey = saved;
              return;
            }
          }
          final key = await DesktopScanItem.keyOf(item.id);
          if (key == null) return;
          item.fileKey = key;
          if (!scanned.contains(item.id)) {
            fresh.add(item);
          } else if (saved == null) {
            // Scanned before file keys were kept: remember it now.
            missing[item.id] = key;
          } else if (key.content != saved.content || key.size != saved.size) {
            // The file changed since: scan it again.
            scanned.remove(item.id);
            tagged.remove(item.id);
          } else {
            // Only its date changed (copied back, touched): keep the scan.
            missing[item.id] = key;
          }
        }(),
    ]);
    await db.saveFileKeys(missing);
    if (fresh.isEmpty) return;
    final same = await db.scannedByContent(fresh.map((i) => i.fileKey!.content));
    for (final item in fresh) {
      final from = same[item.fileKey!.content];
      if (from == null || from == item.id) continue;
      await db.copyScan(from, item.id, item.fileKey!);
      scanned.add(item.id);
      tagged.add(item.id);
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
  /// This device's named people, to send to another of your devices.
  Future<PeoplePackage> peoplePackage() async {
    final skipped = await peopleSyncSkipped();
    return PeoplePackage(
      from: sharing.identity.alias,
      model: faceModelId,
      people: [
        for (final r in await db.peopleForSync())
          if (!skipped.contains(r.syncId)) SyncPerson.fromRow(r),
      ],
    );
  }

  static const _syncSkipKey = 'sync_people_skip';

  /// Named people chosen not to be shared with other devices (by sync id).
  /// Everyone else is shared, so people named later are shared too.
  Future<Set<String>> peopleSyncSkipped() async {
    final saved = await db.setting(_syncSkipKey);
    return saved == null || saved.isEmpty ? <String>{} : saved.split(',').toSet();
  }

  Future<void> setPeopleSyncSkipped(Set<String> ids) => db.setSetting(_syncSkipKey, ids.join(','));

  /// Takes in people from another of your devices: someone already here
  /// (synced before, or with faces alike enough) gets their faces from the
  /// other device and, if unnamed here, their name; anyone else is added,
  /// to be recognised in scans from now on. Then faces are regrouped.
  Future<PeopleSyncResult> takePeople(PeoplePackage package) async {
    if (package.model != faceModelId) return PeopleSyncResult(from: package.from, wrongModel: true);
    final local = await db.peopleForMatching();
    // A little stricter than grouping: joining two people is worse than
    // keeping them apart (that's one merge to fix).
    final matches = matchPeople(package.people, local, thresholds.merge + 0.05);
    var added = 0, matched = 0, named = 0;
    final conflicts = <NameConflict>[];
    for (final (i, p) in package.people.indexed) {
      final m = matches[i];
      final id = await db.addKnownPerson(
        personId: m.localId,
        syncId: p.syncId,
        name: p.name,
        nickname: p.nickname,
        gender: p.gender,
        thumb: p.thumb,
        embeddings: p.embeddings,
        source: package.from,
      );
      if (m.localId == null) {
        added++;
        continue;
      }
      matched++;
      final here = local[id]?.name?.trim();
      if (here == null || here.isEmpty) {
        await db.setPersonNames(id, name: p.name, nickname: p.nickname, gender: p.gender);
        named++;
      } else if (here.toLowerCase() != p.name.toLowerCase()) {
        conflicts.add(NameConflict(localId: id, localName: here, theirName: p.name, thumb: p.thumb));
      }
    }
    // A running scan regroups when it ends.
    if (!running) await regroup();
    changed();
    return PeopleSyncResult(
      from: package.from,
      added: added,
      matched: matched,
      named: named,
      conflicts: conflicts,
    );
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
    // Faces learned from your other devices join in as already-placed
    // faces of their person (made-up ids below zero, never written back),
    // so new faces here that look like them are filed under them.
    final known = [
      for (final e in (await db.knownFaces()).entries)
        for (final v in e.value) (person: e.key, embedding: v),
    ];
    return GroupingInput(
      [for (final f in faces) f.id, for (var i = 0; i < known.length; i++) -1 - i],
      [for (final f in faces) f.embedding, for (final k in known) k.embedding],
      [for (final f in faces) keep(f), for (final k in known) k.person],
      [for (final f in faces) f.locked, for (final _ in known) true],
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

/// "12.3", "4.0", "0.6": photos a second, one decimal (none from 100 up).
String formatRate(double rate) => rate >= 100 ? rate.round().toString() : rate.toStringAsFixed(1);
