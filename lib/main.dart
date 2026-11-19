import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import 'data/db.dart';
import 'platform/app_dirs.dart';
import 'scan/scan_controller.dart';
import 'share/notify.dart';
import 'platform/device.dart';
import 'ui/desktop_keys.dart';
import 'ui/fast_thumb.dart';
import 'ui/island.dart';
import 'ui/root_screen.dart';
import 'ui/theme.dart';
import 'update/updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tuneImageCache();
  // The window opens straight away (on Windows it only appears once
  // something is drawn): if getting ready fails, it says so and offers to
  // try again, instead of ShareBro running invisibly.
  runApp(const _Startup());
}

/// Gets everything ready, then shows the app; a short "Starting" screen
/// meanwhile, and what went wrong if it couldn't.
class _Startup extends StatefulWidget {
  const _Startup();

  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> {
  ScanController? _controller;
  Object? _error;
  String? _logPath;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _error = null;
      _logPath = null;
    });
    try {
      final db = await AppDb.open();
      final controller = ScanController(db);
      await controller.load();
      await Island.load(db);
      await Appearance.load(db);
      await Updater.instance.load(db);
      if (mounted) setState(() => _controller = controller);
    } catch (e, st) {
      debugPrint('ShareBro could not start: $e\n$st');
      final log = await _saveLog(e, st);
      if (mounted) {
        setState(() {
          _error = e;
          _logPath = log;
        });
      }
    }
  }

  /// Writes what went wrong next to ShareBro's data, for reporting it.
  static Future<String?> _saveLog(Object e, StackTrace st) async {
    try {
      final dir = await appDataDir();
      final file = File(p.join(dir.path, 'startup_error.log'));
      await file.writeAsString('${DateTime.now()}\n$e\n$st\n', mode: FileMode.append);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) return PhotoOrganizerApp(controller: controller);
    final dark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    final error = _error;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ShareBro',
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light, colorSchemeSeed: Brand.accentLight),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Builder(builder: (context) {
                final scheme = Theme.of(context).colorScheme;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.asset('assets/icon/app_icon_1024.png', width: 72, height: 72),
                  ),
                  const SizedBox(height: 18),
                  if (error == null) ...[
                    const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                    const SizedBox(height: 14),
                    Text('Starting ShareBro…', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ] else ...[
                    const Text("ShareBro couldn't start",
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    SelectableText('$error',
                        textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                    if (_logPath != null) ...[
                      const SizedBox(height: 8),
                      SelectableText('Details: $_logPath',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(onPressed: _boot, child: const Text('Try again')),
                  ],
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class PhotoOrganizerApp extends StatefulWidget {
  const PhotoOrganizerApp({super.key, required this.controller});

  final ScanController controller;

  @override
  State<PhotoOrganizerApp> createState() => _PhotoOrganizerAppState();
}

/// Follows the phone's light/dark setting (or the one picked in Settings),
/// but instead of snapping, the new look spreads out from the middle of the
/// screen as a growing circle.
class _PhotoOrganizerAppState extends State<PhotoOrganizerApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static Brightness get _wanted => switch (Appearance.mode.value) {
        ThemeMode.light => Brightness.light,
        ThemeMode.dark => Brightness.dark,
        ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness,
      };

  late Brightness _brightness = _wanted;
  final _screen = GlobalKey();
  late final NotifyBridge _notify = NotifyBridge(widget.controller);

  /// Picture of the app in the old theme, shrinking away as a hole grows.
  ui.Image? _old;
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650))
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            setState(() {
              _old?.dispose();
              _old = null;
            });
          }
        });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Appearance.mode.addListener(_apply);
    _notify; // starts following transfers and scans for the notification shade
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Appearance.mode.removeListener(_apply);
    _notify.dispose();
    _reveal.dispose();
    _old?.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _apply();

  Future<void> _apply() async {
    final next = _wanted;
    if (next == _brightness) return;
    ui.Image? shot;
    try {
      final boundary =
          _screen.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary != null && mounted) {
        shot = await boundary.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
      }
    } catch (_) {
      // No snapshot: just switch without the circle.
    }
    if (!mounted) return;
    setState(() {
      _old?.dispose();
      _old = shot;
      _brightness = next;
    });
    if (shot != null) _reveal.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // Fixed "golden hour" brand palette, in light and dark.
    return Builder(builder: (context) {
      return MaterialApp(
        title: 'ShareBro',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(brandScheme(Brightness.light)),
        darkTheme: buildTheme(brandScheme(Brightness.dark)),
        themeMode: _brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        navigatorKey: islandNavigator,
        scaffoldMessengerKey: islandMessenger,
        // The island floats above every screen.
        builder: (context, child) => Island(
          controller: widget.controller,
          child: Stack(children: [
          // On a computer: back keys, the mouse's Back button, F1 shortcuts.
          RepaintBoundary(key: _screen, child: Device.desktop ? DesktopKeys(child: child!) : child),
          if (_old != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _reveal,
                  builder: (context, _) => ClipPath(
                    clipper: _Hole(Curves.easeInOutCubic.transform(_reveal.value)),
                    child: RawImage(image: _old, fit: BoxFit.fill),
                  ),
                ),
              ),
            ),
          ]),
        ),
        home: RootScreen(controller: widget.controller),
      );
    });
  }
}

/// Everything except a circle in the middle that grows to fill the screen.
class _Hole extends CustomClipper<Path> {
  _Hole(this.t);

  final double t;

  @override
  Path getClip(Size size) {
    final r = t * math.sqrt(size.width * size.width + size.height * size.height) / 2;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: size.center(Offset.zero), radius: r));
  }

  @override
  bool shouldReclip(_Hole old) => old.t != t;
}
