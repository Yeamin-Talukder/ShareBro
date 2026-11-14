import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One full loop of the drift. Every movement repeats a whole number of
/// times per loop, so it never jumps when the loop starts over.
const _cycle = Duration(seconds: 90);

/// The lines move so slowly that ~12 updates a second look smooth.
const _frame = Duration(milliseconds: 80);

/// Every this many lines is an "index" line, drawn in the brand coral.
const _index = 5;

/// The background: a faint contour map, like a trail map of the places the
/// trip went, its lines slowly reshaping on a plain ground. No blur, so it's
/// cheap and the glass above stays crisp. Dimmed by [intensity] on busy
/// screens; paused while hidden, still when animations are turned off.
/// [Aurora.celebrate] sends a coral ripple out across the lines (a transfer
/// finished).
class Aurora extends StatefulWidget {
  const Aurora({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// 0..1; quieter on busy screens. Changes fade in smoothly.
  final double intensity;

  static final _waves = ValueNotifier<int>(0);

  /// A coral ripple runs across every visible background.
  static void celebrate() => _waves.value++;

  @override
  State<Aurora> createState() => _AuroraState();
}

/// One clock for every background, so a page sliding in shows the same
/// map as the page under it (and both can reuse one drawing of the lines).
final _clock = Stopwatch()..start();
/// Snapped to whole frames, so backgrounds ticking a moment apart still
/// land on the same step and share one drawing.
double get _now {
  final ms = _clock.elapsedMilliseconds ~/ _frame.inMilliseconds * _frame.inMilliseconds;
  return (ms % _cycle.inMilliseconds) / _cycle.inMilliseconds;
}

class _AuroraState extends State<Aurora> with SingleTickerProviderStateMixin {
  final _t = ValueNotifier<double>(_now);
  Timer? _timer;
  ValueListenable<TickerModeData>? _visible;

  // The drift rests while this page slides or something on it scrolls:
  // every step of it also makes the glass above redo its blur.
  Animation<double>? _in, _over;
  bool _scrolling = false;
  Timer? _scrollRest;
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

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
    final route = ModalRoute.of(context);
    if (route?.animation != _in || route?.secondaryAnimation != _over) {
      _in?.removeStatusListener(_onRoute);
      _over?.removeStatusListener(_onRoute);
      _in = route?.animation?..addStatusListener(_onRoute);
      _over = route?.secondaryAnimation?..addStatusListener(_onRoute);
    }
    _sync();
  }

  void _onRoute(AnimationStatus _) => _sync();

  static bool _moving(Animation<double>? a) =>
      a != null && (a.status == AnimationStatus.forward || a.status == AnimationStatus.reverse);

  /// Rests on any scroll movement and picks up again shortly after the
  /// last one (a timer, not scroll-end, so a list closed mid-fling can't
  /// leave the map stuck).
  bool _onScroll(ScrollNotification n) {
    if (n is! ScrollUpdateNotification && n is! ScrollStartNotification) return false;
    _scrollRest?.cancel();
    _scrollRest = Timer(const Duration(milliseconds: 250), () {
      _scrolling = false;
      _sync();
    });
    if (!_scrolling) {
      _scrolling = true;
      _sync();
    }
    return false;
  }

  /// Runs the drift only while this screen is visible and motion is allowed.
  void _sync() {
    final run = mounted &&
        (_visible?.value.enabled ?? true) &&
        !MediaQuery.disableAnimationsOf(context) &&
        !_moving(_in) &&
        !_moving(_over) &&
        !_scrolling;
    if (run && _timer == null) {
      _timer = Timer.periodic(_frame, (_) => _t.value = _now);
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollRest?.cancel();
    _visible?.removeListener(_sync);
    _in?.removeStatusListener(_onRoute);
    _over?.removeStatusListener(_onRoute);
    Aurora._waves.removeListener(_onWave);
    _wave.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: ColoredBox(
            color: dark
                ? Color.lerp(scheme.surface, const Color(0xFF0B0A0F), 0.85)!
                : Color.lerp(scheme.surface, const Color(0xFFF3F1F5), 0.7)!,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: widget.intensity),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOut,
              builder: (context, strength, _) => CustomPaint(
                size: Size.infinite,
                painter: _ContourPainter(
                  t: _t,
                  wave: _wave,
                  strength: strength,
                  line: dark ? Colors.white.withValues(alpha: 0.085) : const Color(0xFF1A1820).withValues(alpha: 0.085),
                  accent: scheme.primary.withValues(alpha: dark ? 0.22 : 0.2),
                ),
              ),
            ),
          ),
        ),
      ),
      NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
    ]);
  }
}

/// Hills of the map: where each sits (share of width and height), how wide
/// (share of the shorter side), how high, and its drift phase. Peaks near
/// the corners keep the middle, where the content is, the calmest.
const _peaks = [
  (0.10, 0.10, 0.55, 1.0, 0.0),
  (1.02, 0.50, 0.45, 0.85, 2.1),
  (0.20, 0.96, 0.42, 0.8, 4.2),
  (0.70, 0.80, 0.30, 0.35, 1.3),
];

/// Heights the lines are drawn at, from low ground to the peaks.
const _levels = 19;
const _lowest = 0.06, _step = 0.055;

/// Grid the height map is sampled on (logical pixels).
const _cell = 9.0;

/// Traces the map's contour lines: a smooth height map (a few gentle hills
/// plus a slow ripple) cut at even heights with marching squares, so the
/// lines nest like a real map and never cross.
class _ContourPainter extends CustomPainter {
  _ContourPainter({required this.t, required this.wave, required this.strength, required this.line, required this.accent})
      : super(repaint: Listenable.merge([t, wave]));

  final ValueNotifier<double> t;
  final Animation<double> wave;
  final double strength;
  final Color line, accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strength <= 0) return;
    final lines = _lines(size, t.value);

    // "Sent!": a coral glow climbs the hills, level by level.
    final w = wave.value;
    final ripple = w > 0 && w < 1 ? w * (_levels + 2) - 1 : null;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (var l = 0; l < _levels; l++) {
      var color = l % _index == _index - 1 ? accent : line;
      if (ripple != null) {
        final near = 1 - ((l - ripple).abs() / 2).clamp(0.0, 1.0);
        if (near > 0) color = Color.lerp(color, accent.withValues(alpha: 0.75), near)!;
      }
      paint.color = color.withValues(alpha: color.a * strength);
      canvas.drawPath(lines[l], paint);
    }
  }

  /// The traced lines for the last few sizes, at the moment they were
  /// traced. Every background on screen is at the same moment, so they
  /// trace once and share; colour and strength are applied when painting.
  static final _traced = <Size, (double, List<Path>)>{};

  static List<Path> _lines(Size size, double t) {
    final hit = _traced[size];
    if (hit != null && hit.$1 == t) return hit.$2;
    final a = 2 * math.pi * t;
    final cols = (size.width / _cell).ceil() + 1, rows = (size.height / _cell).ceil() + 1;
    final unit = size.shortestSide;
    final hills = [
      for (final (cx, cy, w, h, ph) in _peaks)
        (
          size.width * cx + unit * 0.05 * math.sin(a + ph),
          size.height * cy + unit * 0.04 * math.cos(a * 2 + ph),
          -1 / (2 * math.pow(unit * w, 2)),
          h,
        ),
    ];
    final field = Float64List(cols * rows);
    for (var j = 0; j < rows; j++) {
      final y = j * _cell;
      for (var i = 0; i < cols; i++) {
        final x = i * _cell;
        var v = 0.06 * math.sin(x / unit * 4.2 + a) * math.cos(y / unit * 3.1 - a);
        for (final (hx, hy, k, h) in hills) {
          final dx = x - hx, dy = y - hy;
          v += h * math.exp((dx * dx + dy * dy) * k);
        }
        field[j * cols + i] = v;
      }
    }

    final lines = <Path>[];
    for (var l = 0; l < _levels; l++) {
      final level = _lowest + l * _step;
      final path = Path();
      for (var j = 0; j < rows - 1; j++) {
        for (var i = 0; i < cols - 1; i++) {
          final v0 = field[j * cols + i], v1 = field[j * cols + i + 1];
          final v2 = field[(j + 1) * cols + i + 1], v3 = field[(j + 1) * cols + i];
          final c = (v0 > level ? 8 : 0) | (v1 > level ? 4 : 0) | (v2 > level ? 2 : 0) | (v3 > level ? 1 : 0);
          if (c == 0 || c == 15) continue;
          final x = i * _cell, y = j * _cell;
          double f(double p, double q) => (level - p) / (q - p);
          final top = Offset(x + _cell * f(v0, v1), y);
          final right = Offset(x + _cell, y + _cell * f(v1, v2));
          final bottom = Offset(x + _cell * f(v3, v2), y + _cell);
          final left = Offset(x, y + _cell * f(v0, v3));
          void seg(Offset p, Offset q) => path
            ..moveTo(p.dx, p.dy)
            ..lineTo(q.dx, q.dy);
          switch (c) {
            case 1 || 14:
              seg(left, bottom);
            case 2 || 13:
              seg(bottom, right);
            case 3 || 12:
              seg(left, right);
            case 4 || 11:
              seg(top, right);
            case 5:
              seg(left, top);
              seg(bottom, right);
            case 6 || 9:
              seg(top, bottom);
            case 7 || 8:
              seg(left, top);
            case 10:
              seg(top, right);
              seg(left, bottom);
          }
        }
      }
      lines.add(path);
    }
    if (_traced.length >= 4 && !_traced.containsKey(size)) _traced.remove(_traced.keys.first);
    _traced[size] = (t, lines);
    return lines;
  }

  @override
  bool shouldRepaint(_ContourPainter old) =>
      old.strength != strength || old.line != line || old.accent != accent || old.t != t || old.wave != wave;
}
