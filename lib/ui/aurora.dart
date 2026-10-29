import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One full loop of the flow. Every movement repeats a whole number of
/// times per loop, so it never jumps when the loop starts over.
const _cycle = Duration(seconds: 60);

/// The colours move so slowly that ~15 updates a second look the same as
/// 60, at a quarter of the work (and the glass above re-blurs less often).
const _frame = Duration(milliseconds: 66);

/// How soft the colour shapes are: they melt into one another.
const _softness = 42.0;

/// The background: big soft shapes in the brand's sunset colours slowly
/// melting into each other, like an animated wallpaper. Dimmed by
/// [intensity] on busy screens; paused while hidden, still when animations
/// are turned off. [Aurora.celebrate] sends a warm wave across (a transfer
/// finished).
class Aurora extends StatefulWidget {
  const Aurora({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// 0..1; quieter on busy screens. Changes fade in smoothly.
  final double intensity;

  static final _waves = ValueNotifier<int>(0);

  /// A warm wave washes across every visible background.
  static void celebrate() => _waves.value++;

  @override
  State<Aurora> createState() => _AuroraState();
}

class _AuroraState extends State<Aurora> with SingleTickerProviderStateMixin {
  final _t = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;
  ValueListenable<TickerModeData>? _visible;
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void initState() {
    super.initState();
    Aurora._waves.addListener(_onWave);
  }

  void _onWave() {
    if (mounted && !MediaQuery.disableAnimationsOf(context)) _wave.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible?.removeListener(_sync);
    _visible = TickerMode.getValuesNotifier(context)..addListener(_sync);
    _sync();
  }

  /// Runs the flow only while this screen is visible and motion is allowed.
  void _sync() {
    final run = mounted && (_visible?.value.enabled ?? true) && !MediaQuery.disableAnimationsOf(context);
    if (run && _timer == null) {
      _clock.start();
      _timer = Timer.periodic(_frame, (_) {
        _t.value = (_clock.elapsedMilliseconds % _cycle.inMilliseconds) / _cycle.inMilliseconds;
      });
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _visible?.removeListener(_sync);
    Aurora._waves.removeListener(_onWave);
    _wave.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).colorScheme.surface;
    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.intensity),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            builder: (context, strength, _) => Stack(fit: StackFit.expand, children: [
              // The base sits outside the blur, so the edges never fade out.
              ColoredBox(
                color: dark
                    ? Color.lerp(base, const Color(0xFF0B0816), 0.7)!
                    : Color.lerp(base, const Color(0xFFFFF6F0), 0.7)!,
              ),
              // The colour shapes, melted together by a heavy blur.
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: _softness, sigmaY: _softness, tileMode: TileMode.clamp),
                child: CustomPaint(
                  painter: _FlowPainter(t: _t, wave: _wave, dark: dark, strength: strength, base: base),
                ),
              ),
              // Calm, readable ground on top (no blur needed).
              CustomPaint(painter: _ShadePainter(dark: dark, base: base)),
            ]),
          ),
        ),
      ),
      widget.child,
    ]);
  }
}

/// Sunset coral, rose, violet, teal and a warm peach, as in the app icon:
/// colour, x, y, radius (share of the width), x and y loop counts, phase.
const _shapes = [
  (Color(0xFFFF7A50), 0.32, 0.16, 0.48, 1, 1, 0.0),
  (Color(0xFFE8457A), 0.80, 0.30, 0.44, 1, 2, 1.3),
  (Color(0xFF7B61FF), 0.22, 0.60, 0.52, 2, 1, 2.6),
  (Color(0xFF22C3B0), 0.82, 0.82, 0.46, 1, 1, 3.9),
  (Color(0xFFFFB478), 0.55, 0.44, 0.30, 2, 2, 5.1),
];

class _FlowPainter extends CustomPainter {
  _FlowPainter({required this.t, required this.wave, required this.dark, required this.strength, required this.base})
      : super(repaint: Listenable.merge([t, wave]));

  final ValueNotifier<double> t;
  final Animation<double> wave;
  final bool dark;
  final double strength;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final a = 2 * math.pi * t.value;
    final alpha = (dark ? 0.78 : 0.42) * strength;
    final paint = Paint();
    for (final (color, bx, by, r, fx, fy, ph) in _shapes) {
      final x = w * (bx + 0.16 * math.sin(a * fx + ph));
      final y = h * (by + 0.10 * math.cos(a * fy + ph * 0.7));
      final rx = w * r, ry = rx * (0.8 + 0.2 * math.sin(a * 2 + ph));
      paint.color = color.withValues(alpha: alpha);
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(a + ph);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2), paint);
      canvas.restore();
    }
    // "Sent!": a warm wave sweeps across, then fades.
    final p = wave.value;
    if (p > 0 && p < 1) {
      paint.color = const Color(0xFFFFBE8C).withValues(alpha: (dark ? 0.6 : 0.45) * math.sin(p * math.pi));
      canvas
        ..save()
        ..translate(w * (-0.3 + 1.6 * Curves.easeInOut.transform(p)), h * 0.5)
        ..rotate(0.3);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: w * 0.9, height: h * 1.4), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FlowPainter old) =>
      old.dark != dark || old.strength != strength || old.base != base || old.t != t || old.wave != wave;
}

/// Keeps text readable: the flow toned down a little everywhere, a bit more
/// behind the big titles at the top and the nav bar at the bottom.
class _ShadePainter extends CustomPainter {
  _ShadePainter({required this.dark, required this.base});

  final bool dark;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shade = dark ? const Color(0xFF06040C) : base;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            shade.withValues(alpha: dark ? 0.55 : 0.45),
            shade.withValues(alpha: dark ? 0.38 : 0.30),
            shade.withValues(alpha: dark ? 0.42 : 0.30),
            shade.withValues(alpha: dark ? 0.62 : 0.50),
          ],
          stops: const [0, 0.3, 0.65, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.dark != dark || old.base != base;
}
