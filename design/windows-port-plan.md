# ShareBro for Windows: port plan

Goal: one codebase. Android keeps working exactly as today; Windows gets the
same app, built from the same Flutter code, with the phone-only parts swapped
for desktop versions behind small interfaces.

## Where we start (checked 2026-11-16)

- Flutter 3.47.2 is ready; **Visual Studio 2022 with "Desktop development with
  C++" is not installed** (needed for any Windows build).
- The sharing code (LocalSend protocol, TLS, discovery, web links, Find my
  photos, trip groups) is plain Dart on `dart:io` and should run on Windows
  nearly as is.
- The parts that only work on Android:

| Area | Today | Used in | Windows replacement |
|---|---|---|---|
| Photo library | `photo_manager`, `photo_manager_image_provider` (`AssetEntity`, 53 uses) | 16 files: gallery, scan, viewer, send, receive, server… | Folder-based library: the user adds folders; photos are files, IDs are paths |
| Face finding + eye points | ML Kit face detection | `face/face_engine.dart` | **SCRFD-10G** (InsightFace's detector) run with **ONNX Runtime**. Gives faces + 5 landmarks, the same points the current alignment uses |
| Smile / eyes-open | ML Kit classification | best group shots, "eyes closed" | Phase 4 (small extra model) or hidden on Windows at first |
| Scene labels | ML Kit image labelling | `face_engine.dart`, `face/tags.dart` | Phase 4: a small TFLite classifier, or hidden on Windows at first |
| Face fingerprints | TFLite `w600k_mbf` | `face_engine.dart` | Same model as ONNX (from InsightFace's buffalo_sc), so fingerprints match the phone's |
| Database | `sqflite` | `data/db.dart` | `sqflite_common_ffi` (same API, one setup line) |
| Thumbnails | Kotlin `ThumbChannel` | `ui/fast_thumb.dart` | Dart decode + resize in an isolate, cached to disk |
| Trash | Kotlin `TrashChannel` | `data/trash.dart` | Windows Recycle Bin (via PowerShell / .NET, no extra package) |
| Notifications | Kotlin `NotifyChannel` | `share/notify.dart` | Windows toasts (`local_notifier`), or the in-app island only |
| Installed apps, APK install | Kotlin `AppsChannel` | `data/apps.dart` | Hidden on Windows (Android-only feature) |
| Saving / opening files | Kotlin channel | `share/native_files.dart` | `Downloads\ShareBro`, open with the default app |
| Multicast lock, local IP | Kotlin channel | `share/net.dart` | Not needed on Windows (plain `dart:io`) |
| In-app updater | Kotlin `UpdateChannel` | `update/updater.dart` | Download the Windows installer from Releases |
| Background service | `flutter_foreground_task` | `scan/background.dart` | Not needed: desktop apps keep running |
| No-Wi-Fi sending | `nearby_connections` | `share/nearby.dart` | Hidden on Windows (Android only) |
| Permissions | `permission_handler` | 2 files | Skipped on Windows |
| Videos | `video_player` | `ui/photo_viewer.dart` | Not needed yet: desktop scans photos only; received videos go to Downloads |
| App lock, file picker, share, map, QR | various | — | Already support Windows |

## Approach

Add one small Dart interface per phone-only area (`MediaSource`,
`FaceFinder`, `Thumbs`, `Trash`, `Notifier`, `Files`), with an Android
implementation that wraps today's code unchanged and a Windows one. The app
picks the implementation at start-up (`Platform.isWindows`). Android
behaviour must not change; the existing tests keep passing at every step.

## Phases

### Phase 0: Tooling (1 hour, you)
- Install Visual Studio 2022 Community with **Desktop development with C++**.
- `flutter doctor` shows Visual Studio ✓.

### Phase 1: It builds and opens (≈1–2 days)
- `sqflite_common_ffi` on Windows.
- Guard every Android-only call (`Platform.isAndroid`) so nothing crashes;
  hide features that can't work yet.
- **Done when:** `flutter build windows` succeeds and the app opens to an
  empty People screen without errors.

*Status (2026-11-16): code done; analyze clean, all tests pass. A real
Windows build is still to be checked.*

### Phase 2: Share-only ShareBro for Windows (≈3–5 days)
- Windows `Files`, `Notifier` and network pieces.
- Receive from phones (LocalSend / ShareBro), send files, links and Find my
  photos from the PC, trip groups (joining from the PC).
- **Done when:** a phone sends photos to the PC and the PC sends back, with
  Accept / Decline and history. *This is already useful on its own and can be
  released as a first Windows version.*

*Status: code done (received files go to `Downloads\ShareBro`; the in-app
island stands in for system notifications). Not yet tried on a real PC.*

### Phase 3: Gallery and face scanning (≈1–2 weeks)
- `MediaSource` interface; the Windows version reads chosen folders (with
  EXIF date and GPS), watches them for new photos, and stores file paths as
  photo IDs. Android keeps MediaStore IDs.
- Windows thumbnails (Dart decode, disk cache) and Recycle Bin trash.
- `FaceFinder` interface; Windows uses SCRFD (TFLite) for faces and landmarks,
  then the same alignment, fingerprint model and grouping as Android.
- Bundle the TFLite Windows library (`blobs/libtensorflowlite_c-win.dll`,
  installed by `windows/CMakeLists.txt`).
- Check grouping quality on the demo trip against the Android result.
- **Done when:** scanning a folder on the PC gives the same People groups as
  the phone, within a small margin, at an acceptable speed.

*Status: code done, not yet run on Windows. What changed from the plan:*
- *Face models run on **ONNX Runtime** (the `onnxruntime` plugin bundles
  `onnxruntime.dll`), not a TFLite DLL: InsightFace publishes both models as
  ONNX, so nothing had to be converted. They live in
  `assets/models/desktop/` and are bundled on desktop only (the APK is
  unchanged; `libonnxruntime.so` is excluded from it in Gradle).*
- *`lib/face/scrfd.dart` decodes SCRFD; `test/scrfd_test.dart` checks it
  against InsightFace's own Python decoder on a real photo (within 0.01 px).*
- *Desktop photo ids are file paths. `lib/scan/scan_item.dart` reads a file
  (EXIF date and GPS, engine decode with rotation); `lib/scan/desktop_folders.dart`
  lists a folder; `lib/platform/desktop_library.dart` turns a file into the
  `AssetEntity` the screens expect, and does Recycle Bin and "Show in folder".*
- *Photos tab: every scanned photo. Albums tab: the scanned folders, with
  "Add a folder". Scanned folders are checked for new photos at start-up.*
- *Not on desktop yet: scene labels (Explore categories), smile / eyes-open
  and gender (they need ML Kit or the TFLite gender model), favourites and
  albums (a folder is the album), and HEIC / RAW files.*

### Phase 4: Feature parity (≈1 week, optional)
- Scene labels and smile / eyes-open on Windows (small extra models), so
  Explore, categories and best group shots work.
- Windows video playback.

### Phase 5: Release (≈1–2 days)
- An installer (`msix` package or Inno Setup), app icon, version number.
  *Done: `windows/installer/ShareBro.iss` (Inno Setup; per-user install, adds
  a firewall rule when installed for all users). Window title and version
  info say ShareBro.*
- GitHub Release gets a Windows download next to the APKs; the website and
  README get a "Windows" button.
- **Done when:** a fresh Windows PC installs ShareBro from the website and
  passes a short checklist (open, scan a folder, send to a phone).

## Things to decide

- **Phase 2 first?** Recommended: it ships something useful in about a week,
  before the larger scanning work.
- **Face detector:** SCRFD-10G on ONNX Runtime (decided). It gives the
  landmarks the current alignment needs. It comes from InsightFace, so it has
  the same non-commercial licence as the fingerprint model.
- **One face pipeline everywhere?** Later, Android could also switch to SCRFD
  so both platforms group faces identically. Not required for the port.

## Risks

- Face grouping on Windows may differ slightly from Android until both use
  the same detector.
- Very large folders need careful thumbnail caching to stay fast.
- Windows Firewall asks once to allow ShareBro on private networks; the app
  should explain this, or phones won't find the PC.
