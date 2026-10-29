import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'data/db.dart';
import 'scan/scan_controller.dart';
import 'share/notify.dart';
import 'ui/fast_thumb.dart';
import 'ui/island.dart';
import 'ui/root_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tuneImageCache();
  final db = await AppDb.open();
  final controller = ScanController(db);
  await controller.load();
  await Island.load(db);
  runApp(PhotoOrganizerApp(controller: controller));
}

class PhotoOrganizerApp extends StatefulWidget {
  const PhotoOrganizerApp({super.key, required this.controller});

  final ScanController controller;

  @override
  State<PhotoOrganizerApp> createState() => _PhotoOrganizerAppState();
}

/// Follows the phone's light/dark setting, but instead of snapping, the new
/// look spreads out from the middle of the screen as a growing circle.
class _PhotoOrganizerAppState extends State<PhotoOrganizerApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late Brightness _brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
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
    _notify; // starts following transfers and scans for the notification shade
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notify.dispose();
    _reveal.dispose();
    _old?.dispose();
    super.dispose();
  }

  @override
  Future<void> didChangePlatformBrightness() async {
    final next = WidgetsBinding.instance.platformDispatcher.platformBrightness;
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
          RepaintBoundary(key: _screen, child: child),
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
