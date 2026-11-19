import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/db.dart';
import '../face/face_shape.dart';
import 'desktop_layout.dart';
import 'theme.dart';

/// The face model on a person's page (computer): their real face shape in
/// 3D, turning slowly, lit where ShareBro has seen that side or feature in
/// photos and grey where it hasn't; beside it, how well it knows the face.
class FaceModelPanel extends StatefulWidget {
  const FaceModelPanel({super.key, required this.db, required this.personId, required this.name});

  final AppDb db;
  final int personId;
  final String name;

  @override
  State<FaceModelPanel> createState() => _FaceModelPanelState();
}

/// Shapes being worked out, so opening a person twice doesn't do it twice.
final Map<int, Future<Float32List?>> _shapeJobs = {};

class _FaceModelPanelState extends State<FaceModelPanel> {
  Float32List? _shape;
  FaceModelStats? _stats;
  bool _building = false, _failed = false;
  final _yaw = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _yaw.dispose();
    super.dispose();
  }

  /// Builds the shape again from scratch.
  void _retry() {
    setState(() {
      _failed = false;
      _shape = null;
    });
    _load(force: true);
  }

  Future<void> _load({bool force = false}) async {
    final db = widget.db;
    final stats = await db.faceModelStats(widget.personId);
    final saved = await db.personShape(widget.personId);
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _shape = saved?.points;
    });
    final stale = force || saved == null || FaceShape.stale(faceCount: stats.faces, madeWith: saved.faceCount);
    if (!stale || stats.faces == 0) return;
    setState(() => _building = true);
    try {
      final job = _shapeJobs.putIfAbsent(widget.personId, () => FaceShape.build(db, widget.personId));
      final shape = await job;
      if (!mounted) return;
      setState(() {
        _building = false;
        if (shape != null) _shape = shape;
        _failed = shape == null && _shape == null;
      });
    } catch (e) {
      debugPrint('Face model failed: $e');
      if (mounted) {
        setState(() {
          _building = false;
          _failed = _shape == null;
        });
      }
    } finally {
      _shapeJobs.remove(widget.personId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final scheme = Theme.of(context).colorScheme;
    final shape = _shape;
    final model = SizedBox(
      width: DesktopLayout.on ? 300 : double.infinity,
      height: DesktopLayout.on ? 270 : 320,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF161618) : const Color(0xFFF0F0F3),
          borderRadius: BorderRadius.circular(Mac.cardRadius),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Mac.cardRadius),
          child: shape != null && stats != null
              ? _FaceModel(shape: shape, stats: stats, yaw: _yaw)
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_building || stats == null) ...[
                        const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                        const SizedBox(height: 12),
                        Text('Building ${widget.name}\'s face model…',
                            textAlign: TextAlign.center, style: const TextStyle(fontSize: TextSize.caption)),
                        const SizedBox(height: 2),
                        Text('From their clearest photos, on this ${DesktopLayout.on ? 'computer' : 'phone'}',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
                      ] else ...[
                        Icon(Icons.face_retouching_off_rounded, size: 30, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 10),
                        Text(_failed ? "Couldn't build a face model from these photos yet" : 'No face model yet',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
                        const SizedBox(height: 10),
                        OutlinedButton(onPressed: _retry, child: const Text('Try again')),
                      ],
                    ]),
                  ),
                ),
        ),
      ),
    );
    final facts = stats == null ? const SizedBox(height: 120) : _Facts(stats: stats, name: widget.name, yaw: _yaw);
    if (!DesktopLayout.on) {
      // A phone: the face on top, what's known about it underneath.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [model, const SizedBox(height: 18), facts]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        model,
        const SizedBox(width: 20),
        Expanded(child: facts),
      ]),
    );
  }
}

/// How well the face is known, from 0 to 1, and per side and feature.
class _Known {
  _Known(FaceModelStats s)
      : left = _part(s.left, 20),
        front = _part(s.front, 40),
        right = _part(s.right, 20),
        eyes = _part(s.eyesOpen, 40),
        smile = _part(s.smiling, 20),
        count = _part(s.faces + s.synced, 150),
        sharp = s.sharpness;

  final double left, front, right, eyes, smile, count, sharp;

  static double _part(int n, int full) => math.min(1, n / full);

  double get total => math.min(1, (front * 3 + left + right + eyes + smile) / 7 * (0.6 + 0.4 * sharp));
}

/// MediaPipe face-mesh outlines (point indices), drawn a little stronger
/// so the face reads at a glance.
const _outlines = <(String, List<int>, bool)>[
  ('face', [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136, 172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109], true),
  ('lips', [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185], true),
  ('lips', [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191], true),
  ('eye', [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246], true),
  ('eye', [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466], true),
  ('brow', [46, 53, 52, 65, 55, 70, 63, 105, 66, 107], false),
  ('brow', [276, 283, 282, 295, 285, 300, 293, 334, 296, 336], false),
];

/// The turning wireframe of the person's real face shape.
class _FaceModel extends StatefulWidget {
  const _FaceModel({required this.shape, required this.stats, required this.yaw});

  final Float32List shape;
  final FaceModelStats stats;

  /// Where it's turned now (the gauge beside it follows).
  final ValueNotifier<double> yaw;

  @override
  State<_FaceModel> createState() => _FaceModelState();
}

class _FaceModelState extends State<_FaceModel> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _frame = ValueNotifier(0);
  Duration _last = Duration.zero;
  double _t = 0, _auto = 0, _yawV = 0, _pitch = -0.06;
  double _hoverUntil = 0;
  bool _dragging = false;

  late List<int> _edges;
  late Float32List _known; // per point: how known (0..1)
  late Float32List _patch; // per point: how much knowing it needs (0..1)
  late Offset _centre;
  late double _span;

  double get _yawNow => widget.yaw.value;
  set _yawNow(double v) => widget.yaw.value = v;

  @override
  void initState() {
    super.initState();
    _prepare();
    _ticker.start();
  }

  @override
  void didUpdateWidget(_FaceModel old) {
    super.didUpdateWidget(old);
    if (!identical(old.shape, widget.shape) || old.stats != widget.stats) _prepare();
  }

  void _prepare() {
    final s = widget.shape;
    const n = FaceShape.points;
    _edges = faceShapeEdges(s);
    var minX = double.infinity, maxX = -double.infinity, minY = double.infinity, maxY = -double.infinity;
    for (var i = 0; i < n; i++) {
      minX = math.min(minX, s[i * 3]);
      maxX = math.max(maxX, s[i * 3]);
      minY = math.min(minY, s[i * 3 + 1]);
      maxY = math.max(maxY, s[i * 3 + 1]);
    }
    _centre = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    _span = math.max(maxX - minX, maxY - minY);
    // Which part each point is, and how known that part is.
    final k = _Known(widget.stats);
    Offset at(int i) => Offset(s[i * 3], s[i * 3 + 1]);
    final eyeA = (at(33) + at(133)) / 2, eyeB = (at(263) + at(362)) / 2;
    final mouth = (at(13) + at(14) + at(61) + at(291)) / 4;
    final half = (maxX - minX) / 2;
    _known = Float32List(n);
    _patch = Float32List(n);
    for (var i = 0; i < n; i++) {
      final p = at(i);
      final xn = (p.dx - _centre.dx) / half; // -1 left edge .. 1 right edge
      double v;
      if (xn < -0.35) {
        final w = ((-xn - 0.35) / 0.45).clamp(0.0, 1.0);
        v = k.left * w + k.front * (1 - w);
      } else if (xn > 0.35) {
        final w = ((xn - 0.35) / 0.45).clamp(0.0, 1.0);
        v = k.right * w + k.front * (1 - w);
      } else {
        v = k.front;
      }
      if ((p - eyeA).distance < 0.32 || (p - eyeB).distance < 0.32) v = math.min(v, k.eyes);
      final m = p - mouth;
      if ((m.dx / 0.55) * (m.dx / 0.55) + (m.dy / 0.28) * (m.dy / 0.28) < 1) v = math.min(v, 0.35 + 0.65 * k.smile);
      _known[i] = v;
      // Known areas grow from the middle of the face outward.
      _patch[i] = (math.sqrt(xn * xn + math.pow((p.dy - _centre.dy) / ((maxY - minY) / 2), 2)) * 0.8 + 0.05).clamp(0.02, 0.98);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    _t += dt;
    final still = MediaQuery.disableAnimationsOf(context);
    final hovering = _t < _hoverUntil;
    if (!_dragging) {
      if (_yawV.abs() > 0.0005) {
        _yawNow = (_yawNow + _yawV).clamp(-1.2, 1.2);
        _yawV *= math.pow(0.93, dt * 60).toDouble();
        _auto = math.asin((_yawNow / 0.85).clamp(-1.0, 1.0)) / 0.5;
      } else if (!hovering && !still && _t > 1.5) {
        _auto += dt;
        final goal = math.sin(_auto * 0.5) * 0.85;
        _yawNow += (goal - _yawNow) * (1 - math.pow(0.96, dt * 60));
      }
    }
    _frame.value++;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Listener(
      // Two fingers here turn the face, not the page.
      onPointerPanZoomStart: (_) => NavSwipe.claim(),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onHover: (_) => _hoverUntil = _t + 1.2,
        onExit: (_) => _hoverUntil = 0,
        child: GestureDetector(
          onPanStart: (_) {
            _dragging = true;
            _yawV = 0;
          },
          onPanUpdate: (d) {
            _yawNow = (_yawNow + d.delta.dx * 0.008).clamp(-1.2, 1.2);
            _yawV = d.delta.dx * 0.008;
            _pitch = (_pitch + d.delta.dy * 0.004).clamp(-0.45, 0.35);
          },
          onPanEnd: (_) => _dragging = false,
          onDoubleTap: () {
            _yawV = 0;
            _auto = 0;
            _yawNow = 0;
            _pitch = -0.06;
          },
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MeshPainter(
                  repaint: _frame,
                  state: this,
                  accent: scheme.primary,
                  off: dark ? const Color(0xFF4A4A4E) : const Color(0xFFC7C7CC),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: IgnorePointer(
                child: Text('Drag to turn · ${DesktopLayout.on ? 'double-click' : 'double-tap'} to face front',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: TextSize.tiny, color: scheme.onSurfaceVariant)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({required Listenable repaint, required this.state, required this.accent, required this.off})
      : super(repaint: repaint);

  final _FaceModelState state;
  final Color accent, off;

  @override
  void paint(Canvas canvas, Size size) {
    final st = state;
    final s = st.widget.shape;
    const n = FaceShape.points;
    final yaw = st._yawNow, pitch = st._pitch;
    final cy = math.cos(yaw), sy = math.sin(yaw), cp = math.cos(pitch), sp = math.sin(pitch);
    final scale = math.min(size.width, size.height - 24) * 0.86 / st._span;
    final ox = size.width / 2, oy = (size.height - 18) / 2;
    final xs = Float32List(n), ys = Float32List(n), zs = Float32List(n);
    for (var i = 0; i < n; i++) {
      final x = s[i * 3] - st._centre.dx, y = s[i * 3 + 1] - st._centre.dy, z = s[i * 3 + 2];
      final x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
      final y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp;
      final f = 4 / (4 - z2);
      xs[i] = ox + x1 * scale * f;
      ys[i] = oy + y2 * scale * f;
      zs[i] = z2;
    }
    // It builds in from the top, like a scan.
    final scan = MediaQuery.disableAnimationsOf(st.context) ? 1.0 : (st._t / 1.4).clamp(0.0, 1.0);
    final scanY = oy - st._span * scale * 0.55 + st._span * scale * 1.15 * scan;
    // Shimmer while the face is barely known.
    final k = _Known(st.widget.stats);
    final unsure = (1 - k.count) * (1 - k.sharp * 0.6);

    final faint = Paint()
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    final lit = Paint()
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;
    // Depth of the face's front, to fade the far side.
    var zMax = -double.infinity, zMin = double.infinity;
    for (var i = 0; i < n; i++) {
      zMax = math.max(zMax, zs[i]);
      zMin = math.min(zMin, zs[i]);
    }
    double depth(int i) => ((zs[i] - zMin) / math.max(1e-6, zMax - zMin));
    bool known(int i) => st._known[i] > st._patch[i];

    final e = st._edges;
    for (var pass = 0; pass < 2; pass++) {
      for (var j = 0; j < e.length; j += 2) {
        final a = e[j], b = e[j + 1];
        if (ys[a] > scanY || ys[b] > scanY) continue;
        final on = known(a) && known(b);
        if ((pass == 1) != on) continue;
        final d = (depth(a) + depth(b)) / 2;
        final alpha = (0.12 + 0.78 * d * d).clamp(0.0, 1.0);
        final jitter = unsure > 0 ? math.sin(st._t * 3 + a) * unsure * 0.8 : 0.0;
        final paint = on ? lit : faint;
        paint.color = (on ? accent : off).withValues(alpha: alpha);
        canvas.drawLine(Offset(xs[a] + jitter, ys[a]), Offset(xs[b] + jitter, ys[b]), paint);
      }
    }

    // Outlines on top: face, eyes, brows, lips.
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final featureKnown = {
      'face': k.front,
      'eye': k.eyes * math.max(k.front, 0.3),
      'brow': k.front,
      'lips': (0.35 + 0.65 * k.smile) * k.front,
    };
    for (final (part, idx, closed) in _outlines) {
      final kv = featureKnown[part]!;
      final count = closed ? idx.length : idx.length - 1;
      for (var j = 0; j < count; j++) {
        final a = idx[j], b = idx[(j + 1) % idx.length];
        if (ys[a] > scanY || ys[b] > scanY) continue;
        final d = (depth(a) + depth(b)) / 2;
        if (part != 'face' && d < 0.35) continue;
        line.color = Color.lerp(off, accent, kv.clamp(0.0, 1.0))!.withValues(alpha: (0.25 + 0.75 * d).clamp(0.0, 1.0));
        canvas.drawLine(Offset(xs[a], ys[a]), Offset(xs[b], ys[b]), line);
      }
    }

    if (scan < 1) {
      final band = Paint()..color = accent.withValues(alpha: 0.85);
      canvas.drawRect(Rect.fromLTWH(ox - st._span * scale * 0.55, scanY - 1, st._span * scale * 1.1, 2), band);
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) => old.accent != accent || old.off != off || old.state != state;
}

/// Beside the model: how well the face is known, from which sides, and a
/// tip about what's missing.
class _Facts extends StatelessWidget {
  const _Facts({required this.stats, required this.name, required this.yaw});

  final FaceModelStats stats;
  final String name;
  final ValueNotifier<double> yaw;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final k = _Known(stats);
    final pct = (k.total * 100).round();
    final first = name.split(' ').first;
    final tip = stats.faces < 5
        ? 'Only ${stats.faces} ${stats.faces == 1 ? 'photo' : 'photos'} of $first so far. More photos fill the model in.'
        : stats.right == 0
            ? 'No photos of $first turned to the right yet. Photos from that side make recognition surer.'
            : stats.left == 0
                ? 'No photos of $first turned to the left yet. Photos from that side make recognition surer.'
                : stats.smiling == 0
                    ? 'No smiling photos of $first yet, so the mouth stays grey.'
                    : 'ShareBro knows $first\'s face well from every side.';
    Widget stat(String value, String label) => Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            decoration: BoxDecoration(
              border: Border.all(color: Mac.hairline(context), width: 0.5),
              borderRadius: BorderRadius.circular(Mac.controlRadius),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: const TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
              Text(label, style: TextStyle(fontSize: TextSize.tiny, color: scheme.onSurfaceVariant)),
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('$pct%', style: text.headlineMedium),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text('of $first\'s face known', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(value: k.total, minHeight: 6),
      ),
      const SizedBox(height: 14),
      Row(children: [
        SizedBox(
          width: 132,
          height: 74,
          child: ValueListenableBuilder<double>(
            valueListenable: yaw,
            builder: (context, y, _) => CustomPaint(
              painter: _Gauge(k: k, yaw: y, accent: scheme.primary, off: Mac.hairline(context), ink: scheme.onSurface),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Seen from', style: TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            for (final (label, n) in [('Left', stats.left), ('Front', stats.front), ('Right', stats.right)])
              Row(children: [
                SizedBox(width: 48, child: Text(label, style: const TextStyle(fontSize: TextSize.caption))),
                Text('$n', style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600, color: n == 0 ? scheme.onSurfaceVariant : null)),
              ]),
          ]),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        stat('${stats.eyesOpen}', 'eyes open'),
        const SizedBox(width: 8),
        stat('${stats.smiling}', 'smiling'),
        const SizedBox(width: 8),
        stat('${(stats.sharpness * 100).round()}%', 'sharp'),
        const SizedBox(width: 8),
        stat(stats.synced == 0 ? '0' : '+${stats.synced}', 'from devices'),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Mac.controlRadius),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.info_outline_rounded, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(tip, style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant))),
        ]),
      ),
    ]);
  }
}

/// "Seen from": three arcs (left, front, right) filled by how much of that
/// side is known, and a needle where the model is turned now.
class _Gauge extends CustomPainter {
  _Gauge({required this.k, required this.yaw, required this.accent, required this.off, required this.ink});

  final _Known k;
  final double yaw;
  final Color accent, off, ink;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height - 6);
    final r = math.min(size.width / 2, size.height) - 10;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: c, radius: r);
    final parts = [(math.pi, math.pi * 0.36, k.left), (math.pi * 1.38, math.pi * 0.24, k.front), (math.pi * 1.64, math.pi * 0.36, k.right)];
    for (final (start, sweep, v) in parts) {
      arc.color = off;
      canvas.drawArc(rect, start + 0.04, sweep - 0.08, false, arc);
      if (v > 0) {
        arc.color = accent;
        canvas.drawArc(rect, start + 0.04, (sweep - 0.08) * v, false, arc);
      }
    }
    final a = math.pi * 1.5 + (yaw / 1.2).clamp(-1.0, 1.0) * math.pi * 0.5;
    final needle = Paint()
      ..color = ink
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(c, c + Offset(math.cos(a), math.sin(a)) * (r - 12), needle);
    canvas.drawCircle(c, 3.5, Paint()..color = ink);
  }

  @override
  bool shouldRepaint(_Gauge old) => old.yaw != yaw || old.accent != accent || old.k != k;
}

/// Phone: a person's face model on its own page (from the person's menu).
class FaceModelScreen extends StatelessWidget {
  const FaceModelScreen({super.key, required this.db, required this.personId, required this.name});

  final AppDb db;
  final int personId;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("$name's face")),
      body: SingleChildScrollView(
        child: FaceModelPanel(db: db, personId: personId, name: name),
      ),
    );
  }
}
