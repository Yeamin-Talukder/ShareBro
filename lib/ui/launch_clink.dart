import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opening animation, "Cheers": the logo's two phones fall in and clink at
/// the top like glasses in a toast. They squash and bounce on contact, their
/// screens light up, rings and sparkles fly out of the clink, the spark
/// flicks on and "ShareBro" drops in letter by letter. Then it all fades.
/// With animations turned off, the finished logo just shows briefly.
class LaunchClink extends StatefulWidget {
  const LaunchClink({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<LaunchClink> createState() => _LaunchClinkState();
}

/// Whole sequence (seconds), then the fade.
const _length = 1.95;
const _fade = Duration(milliseconds: 350);

/// When the phones touch.
const _hit = 0.62;

const _word = 'ShareBro';

class _LaunchClinkState extends State<LaunchClink> with TickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Duration(milliseconds: (_length * 1000).round()));
  late final AnimationController _out = AnimationController(vsync: this, duration: _fade);
  bool _buzzed = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(() {
      if (!_buzzed && _c.value * _length >= _hit) {
        _buzzed = true;
        HapticFeedback.lightImpact();
      }
    });
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _out.forward().whenComplete(widget.onDone);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      // Motion off: the finished logo, a moment, then away.
      _buzzed = true;
      _c.value = 1;
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _out.forward().whenComplete(widget.onDone);
      });
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    // The logo's drawing area is 68 x 62 units of the icon's 108 grid.
    final unit = math.min(3.4, size.width * 0.62 / 68);
    return Positioned.fill(
      child: FadeTransition(
        opacity: ReverseAnimation(_out),
        child: ColoredBox(
          color: scheme.surface,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = _c.value * _length;
              return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CustomPaint(
                  size: Size(68 * unit, 62 * unit),
                  painter: _ClinkPainter(
                    t: t,
                    unit: unit,
                    shadow: Colors.black.withValues(alpha: scheme.brightness == Brightness.dark ? 0.6 : 0.18),
                  ),
                ),
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final (i, ch) in _word.split('').indexed)
                    _letter(ch, _progress(t, 0.9 + i * 0.04, 0.45), text),
                ]),
                const SizedBox(height: 2),
                Opacity(
                  opacity: Curves.easeOut.transform(_progress(t, 1.3, 0.5)),
                  child: Text('Share trip photos with friends',
                      style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _letter(String ch, double p, TextTheme text) {
    final pop = Curves.easeOutBack.transform(p);
    return Opacity(
      opacity: Curves.easeOut.transform(p),
      child: Transform.translate(
        offset: Offset(0, 14 * (1 - pop)),
        child: Transform.scale(
          scale: 0.8 + 0.2 * pop,
          child: Text(ch,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4, fontSize: 28)),
        ),
      ),
    );
  }
}

/// 0..1 through a step that starts at [start] and lasts [length] seconds.
double _progress(double t, double start, double length) => ((t - start) / length).clamp(0.0, 1.0);

/// One pose of a falling phone: offset (icon units), turn (degrees), squash.
class _Pose {
  const _Pose(this.at, this.dx, this.dy, this.turn, [this.sx = 1, this.sy = 1, this.curve = Curves.ease]);

  /// Share of the fall (0..1) this pose is reached at.
  final double at;
  final double dx, dy, turn, sx, sy;

  /// How it moves on to the next pose.
  final Curve curve;
}

/// The left phone's fall: a wind-up on the way down, a squash on contact,
/// a bounce apart and a small wobble. The right phone mirrors it.
const _fall = [
  _Pose(0, -18, -110, -38, 1, 1, Cubic(.55, 0, .85, .35)),
  _Pose(.50, -3, 0, -4, 1, 1, Cubic(.2, .8, .3, 1)),
  _Pose(.55, -1, 1, 2, 1.04, .95),
  _Pose(.68, 1, -1.5, 5, .98, 1.03),
  _Pose(.82, -.5, 0, -1.5),
  _Pose(.92, 0, 0, .6),
  _Pose(1, 0, 0, 0),
];
const _fallTime = 1.25;

_Pose _poseAt(double f) {
  for (var i = 0; i < _fall.length - 1; i++) {
    final a = _fall[i], b = _fall[i + 1];
    if (f <= b.at) {
      final k = a.curve.transform(((f - a.at) / (b.at - a.at)).clamp(0.0, 1.0));
      double l(double x, double y) => x + (y - x) * k;
      return _Pose(f, l(a.dx, b.dx), l(a.dy, b.dy), l(a.turn, b.turn), l(a.sx, b.sx), l(a.sy, b.sy));
    }
  }
  return _fall.last;
}

class _Phone {
  const _Phone(this.body, this.sky, this.sun, this.hill, this.hill2, this.slot);

  final Color body, sky, sun, hill, hill2, slot;
}

const _coral = _Phone(
    Color(0xFFE5533A), Color(0xFFFDE3DA), Color(0xFFFF8A6B), Color(0xFFFFC3B2), Color(0xFFFF8A6B), Color(0xFFB23A25));
const _ink = _Phone(
    Color(0xFF141217), Color(0xFF3A353F), Color(0xFFFF8A6B), Color(0xFF5A5560), Color(0xFF8A8590), Color(0xFF000000));
const _sparkColor = Color(0xFFE5533A);

/// Where the phones sit in the icon's 108 grid (see tool/make_icon.py).
const _left = Offset(40.3, 57.6), _right = Offset(67.7, 57.6);
const _clink = Offset(54, 41);

/// Bits thrown out of the clink: colour, square or round.
const _bits = [
  (Color(0xFFE5533A), false),
  (Color(0xFFFF8A6B), true),
  (Color(0xFF141217), false),
  (Color(0xFFFFC3B2), true),
  (Color(0xFFE5533A), false),
  (Color(0xFF8A8590), true),
  (Color(0xFFFF8A6B), false),
  (Color(0xFFE5533A), true),
];

class _ClinkPainter extends CustomPainter {
  _ClinkPainter({required this.t, required this.unit, required this.shadow});

  /// Seconds into the animation.
  final double t;
  final double unit;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(unit);
    // Show the part of the 108 grid around the logo.
    canvas.translate(-20, -22);

    final fall = (t / _fallTime).clamp(0.0, 1.0);

    // Shadow lands under the phones.
    final sh = _shadowScale(fall);
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(54, 79), width: 48 * sh.$1, height: 4.4),
      Paint()..color = shadow.withValues(alpha: shadow.a * sh.$2),
    );

    final pose = _poseAt(fall);
    final opacity = (fall / .12).clamp(0.0, 1.0);
    _phone(canvas, _coral, _left, 22.5, pose, 1, opacity);
    _phone(canvas, _ink, _right, -22.5, pose, -1, opacity);

    // Two rings ripple out of the clink.
    _ring(canvas, _progress(t, .64, .7));
    _ring(canvas, _progress(t, .72, .8));
    _bitsOut(canvas, _progress(t, .64, .8));
    _spark(canvas, _progress(t, .66, .45));
  }

  /// Width scale and opacity of the shadow.
  (double, double) _shadowScale(double f) {
    if (f < .5) {
      final k = Curves.ease.transform(f / .5);
      return (.2 + .9 * k, k);
    }
    if (f < .62) return (1.1 - .18 * Curves.ease.transform((f - .5) / .12), 1);
    return (.92 + .08 * Curves.ease.transform((f - .62) / .38), 1);
  }

  void _phone(Canvas canvas, _Phone c, Offset at, double tilt, _Pose p, double side, double opacity) {
    canvas.save();
    canvas.translate(at.dx + p.dx * side, at.dy + p.dy);
    canvas.rotate(p.turn * side * math.pi / 180);
    canvas.scale(p.sx, p.sy);
    canvas.rotate(tilt * math.pi / 180);
    if (opacity < 1) {
      canvas.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: opacity));
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(-9.37, -16.7, 18.74, 33.4), const Radius.circular(4.37)),
        Paint()..color = c.body);
    final screen = RRect.fromRectAndRadius(const Rect.fromLTWH(-8.1, -13.4, 16.2, 28.9), const Radius.circular(3.3));
    canvas.save();
    canvas.clipRRect(screen);
    canvas.drawRect(screen.outerRect, Paint()..color = c.sky);
    canvas.drawCircle(const Offset(2.6, -5.2), 2.1, Paint()..color = c.sun);
    canvas.drawPath(
      Path()
        ..moveTo(-8.1, 4.5)
        ..lineTo(-2.6, -0.6)
        ..lineTo(0.2, 6)
        ..lineTo(4, 3.5)
        ..lineTo(8.1, 9)
        ..lineTo(8.1, 15.5)
        ..lineTo(-8.1, 15.5)
        ..close(),
      Paint()..color = c.hill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(-8.1, 9.6)
        ..lineTo(-2.6, 7.4)
        ..lineTo(0, 12)
        ..lineTo(3, 10.6)
        ..lineTo(5.5, 12.2)
        ..lineTo(8.1, 15.5)
        ..lineTo(-8.1, 15.5)
        ..close(),
      Paint()..color = c.hill2,
    );
    // Asleep while falling; a bright flash on the clink, then awake.
    final wake = _progress(t, .6, .7);
    final glow = wake < .35
        ? Color.lerp(Colors.black.withValues(alpha: .6), Colors.white.withValues(alpha: .3), wake / .35)!
        : Colors.white.withValues(alpha: .3 * (1 - (wake - .35) / .65));
    canvas.drawRect(screen.outerRect, Paint()..color = glow);
    canvas.restore();
    canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(-2.1, -15.6, 4.2, 1.24), const Radius.circular(.62)),
        Paint()..color = c.slot);
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  void _ring(Canvas canvas, double p) {
    if (p <= 0 || p >= 1) return;
    final k = Curves.easeOut.transform(p);
    canvas.drawCircle(
      const Offset(54, 40),
      1 + 19 * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 - k
        ..color = _sparkColor.withValues(alpha: .7 * (1 - k)),
    );
  }

  void _bitsOut(Canvas canvas, double p) {
    if (p <= 0 || p >= 1) return;
    final k = const Cubic(.15, .7, .3, 1).transform(p);
    final fade = p < .7 ? 1.0 : 1 - (p - .7) / .3;
    for (final (i, (color, square)) in _bits.indexed) {
      final a = (-160 + i * 20) * math.pi / 180;
      final r = 14.0 + (i % 3) * 5;
      final to = _clink + Offset(math.cos(a), math.sin(a)) * r;
      final at = Offset.lerp(_clink, to, k)!;
      final paint = Paint()..color = color.withValues(alpha: fade);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(i * 40 * k * math.pi / 180);
      canvas.scale(k);
      if (square) {
        canvas.drawRRect(
            RRect.fromRectAndRadius(const Rect.fromLTWH(-.9, -.9, 1.8, 1.8), const Radius.circular(.4)), paint);
      } else {
        canvas.drawCircle(Offset.zero, 1, paint);
      }
      canvas.restore();
    }
  }

  void _spark(Canvas canvas, double p) {
    if (p <= 0) return;
    final k = Curves.easeOutBack.transform(p);
    final paint = Paint()
      ..color = _sparkColor.withValues(alpha: p.clamp(0.0, 1.0))
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in const [
      (Offset(54, 36.3), Offset(54, 32.8)),
      (Offset(55.9, 37.2), Offset(58.6, 35)),
      (Offset(52.1, 37.2), Offset(49.4, 35)),
    ]) {
      canvas.drawLine(from, Offset.lerp(from, to, k)!, paint);
    }
  }

  @override
  bool shouldRepaint(_ClinkPainter old) => old.t != t || old.unit != unit || old.shadow != shadow;
}
