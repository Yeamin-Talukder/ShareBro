import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/db.dart';
import 'motion.dart';
import 'widgets.dart';

/// Ways to see People: the grid and bubbles, and six spatial views you
/// move with a finger.
enum PeopleLayout {
  grid('Grid', Icons.grid_view_rounded),
  bubbles('Bubbles', Icons.bubble_chart_rounded),
  honeycomb('Honeycomb', Icons.hexagon_rounded),
  sunflower('Sunflower', Icons.filter_vintage_rounded),
  globe('Globe', Icons.public_rounded),
  orbit('Orbit', Icons.track_changes_rounded),
  magnifier('Magnifier', Icons.zoom_in_rounded),
  carousel('Carousel', Icons.view_carousel_rounded);

  const PeopleLayout(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Laid out by [PeopleSpace].
  bool get spatial => index >= PeopleLayout.honeycomb.index;

  static PeopleLayout byName(String? name) => values.firstWhere((v) => v.name == name, orElse: () => grid);
}

/// Where a face wants to be this frame, and how it looks there.
class _Target {
  const _Target(this.pos, this.scale, this.opacity, this.depth, this.label);

  final Offset pos;
  final double scale, opacity, depth;
  final bool label;
}

/// Where a face is now; it eases towards its [_Target] every frame, so
/// switching views (or flinging) glides instead of jumping.
class _Node {
  Offset pos = Offset.zero;
  double scale = 0.2, opacity = 0;
  _Target? target;
}

/// The spatial People views: everyone at once, moved as a group with a
/// finger. Faces grow near the focus and shrink and fade away from it;
/// tap one to open the person.
class PeopleSpace extends StatefulWidget {
  const PeopleSpace({super.key, required this.people, required this.layout, required this.onOpen, this.hubLabel});

  final List<PersonSummary> people;
  final PeopleLayout layout;
  final ValueChanged<PersonSummary> onOpen;

  /// What the middle of the Orbit says (the trip, or everyone).
  final String? hubLabel;

  @override
  State<PeopleSpace> createState() => _PeopleSpaceState();
}

const _size = 84.0;
const _half = _size / 2;

class _PeopleSpaceState extends State<PeopleSpace> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _frame = ValueNotifier(0);
  Duration _last = Duration.zero;
  double _now = 0, _switchedAt = 0;
  Size _area = Size.zero;
  bool _still = false;

  /// People, most photos first, and where each one's face is.
  late List<PersonSummary> _people;
  final Map<int, _Node> _nodes = {};

  // What a finger has done to each view, and how fast it's still going.
  Offset _pan = Offset.zero, _panV = Offset.zero;
  double _rot = 0, _rotV = 0;
  double _yaw = 0, _yawV = 0, _pitch = -0.25, _pitchV = 0;
  double _spin = 0, _spinV = 0;
  double _drum = 0, _drumV = 0;
  int _drumColumn = 0;
  Offset _lens = Offset.zero;
  double _lensOn = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _sort();
    _kick();
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didUpdateWidget(PeopleSpace old) {
    super.didUpdateWidget(old);
    if (old.people != widget.people) _sort();
    if (old.layout != widget.layout) {
      _switchedAt = _now;
      _kick();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _sort() {
    _people = [...widget.people]..sort((a, b) => b.photoCount.compareTo(a.photoCount));
    final ids = {for (final p in _people) p.id};
    _nodes.removeWhere((id, _) => !ids.contains(id));
  }

  /// A small push when a view opens, so it shows it can move.
  void _kick() {
    _panV = Offset.zero;
    _pan = Offset.zero;
    _rotV = _yawV = _pitchV = _spinV = _drumV = 0;
    if (_still) return;
    switch (widget.layout) {
      case PeopleLayout.honeycomb:
        _panV = const Offset(-5, -3);
      case PeopleLayout.sunflower:
        _rotV = 0.05;
      case PeopleLayout.globe:
        _yawV = 0.07;
        _pitchV = 0.015;
      case PeopleLayout.orbit:
        _spinV = 0.06;
      case PeopleLayout.carousel:
        _drumV = 0.16;
      default:
        break;
    }
  }

  /// How many faces each view shows (the people with the most photos).
  int get _cap => switch (widget.layout) {
        PeopleLayout.orbit => 31,
        PeopleLayout.globe => 60,
        _ => 90,
      };

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    _now = elapsed.inMicroseconds / 1e6;
    if (_area.isEmpty) return;
    final f = dt * 60; // velocities are per 60 fps frame
    double decay(double per) => math.pow(per, f).toDouble();
    if (!_dragging) {
      _pan += _panV * f;
      _panV *= decay(0.94);
      _rot += _rotV * f;
      _rotV *= decay(0.95);
      _yaw += _yawV * f;
      _pitch = (_pitch + _pitchV * f).clamp(-1.1, 1.1);
      _yawV *= decay(0.96);
      _pitchV *= decay(0.93);
      _spin += _spinV * f;
      _spinV *= decay(0.95);
      _drum += _drumV * f;
      _drumV *= decay(0.93);
      if (!_still) {
        // Globe and sunflower keep turning gently on their own.
        if (widget.layout == PeopleLayout.globe && _yawV.abs() < 0.002) _yaw += 0.0035 * f;
        if (widget.layout == PeopleLayout.sunflower && _rotV.abs() < 0.001) _rot += 0.0012 * f;
      }
      if (widget.layout == PeopleLayout.honeycomb) _pan *= decay(0.995);
      if (widget.layout == PeopleLayout.carousel && _drumV.abs() < 0.004) {
        // Settle on the nearest column.
        final step = 2 * math.pi / _drumColumns;
        final goal = (_drum / step).round() * step;
        _drum += (goal - _drum) * (1 - decay(0.88));
      }
      _lensOn *= decay(0.94);
    }
    if (widget.layout == PeopleLayout.carousel) {
      final column = (-_drum / (2 * math.pi / _drumColumns)).round();
      if (column != _drumColumn) {
        _drumColumn = column;
        Haptics.tick();
      }
    }

    final people = _people.take(_cap).toList();
    final targets = _targets(people.length);
    // Ease towards the targets: slowly while views morph, briskly after.
    final rate = _still ? 1.0 : (_now - _switchedAt < 0.9 ? 0.085 : 0.32);
    final k = 1 - math.pow(1 - rate, f).toDouble();
    for (final (i, p) in people.indexed) {
      final n = _nodes.putIfAbsent(p.id, () => _Node()..pos = _area.center(Offset.zero));
      final g = targets[i];
      n.target = g;
      n.pos = Offset.lerp(n.pos, g.pos, k)!;
      n.scale += (g.scale - n.scale) * k;
      n.opacity += (g.opacity - n.opacity) * k;
    }
    _frame.value++;
  }

  int get _drumColumns => math.max(1, (math.min(_people.length, _cap) / 3).ceil());

  List<_Target> _targets(int count) {
    final w = _area.width, h = _area.height;
    final c = Offset(w / 2, h / 2);
    final k = w / 412; // the demo was drawn at 412 wide
    final out = <_Target>[];
    switch (widget.layout) {
      case PeopleLayout.honeycomb:
        for (final hex in _hex(count)) {
          final p = c + hex * k + _pan;
          final d = math.sqrt(math.pow(p.dx - c.dx, 2) + math.pow((p.dy - c.dy) * 1.1, 2));
          final s = (1.12 - d / (260 * k)).clamp(0.3, 1.04);
          out.add(_Target(p, s, 1, s, s > 0.95));
        }
      case PeopleLayout.sunflower:
        // Golden angle; spacing shrinks with more people so everyone fits.
        final spacing = math.min(40 * k, (math.min(w, h) / 2 - 16) / math.sqrt(count + 0.5));
        final size = spacing / (40 * k);
        for (var i = 0; i < count; i++) {
          final a = i * 2.39996 + _rot, r = spacing * math.sqrt(i + 0.5);
          final breathe = _still ? 1 : 1 + 0.03 * math.sin(_now * 1.6 + i);
          final s = math.max(0.4, 0.86 - i * 0.016) * size * breathe;
          out.add(_Target(c + Offset(r * math.cos(a), r * math.sin(a)), s, 1, 1 - i / count, i == 0));
        }
      case PeopleLayout.globe:
        final cy = math.cos(_yaw), sy = math.sin(_yaw), cp = math.cos(_pitch), sp = math.sin(_pitch);
        final radius = math.min(196 * k, h * 0.4);
        final crowd = math.min(1.0, math.sqrt(30 / math.max(1, count)));
        for (var i = 0; i < count; i++) {
          // Points spread evenly over a sphere, then turned.
          var y = 1 - 2 * (i + 0.5) / count;
          final ring = math.sqrt(1 - y * y), a = i * 2.39996;
          var x = math.cos(a) * ring, z = math.sin(a) * ring;
          (x, z) = (x * cy + z * sy, -x * sy + z * cy);
          (y, z) = (y * cp - z * sp, y * sp + z * cp);
          final depth = (z + 1) / 2, persp = 1 / (1.6 - z * 0.45);
          out.add(_Target(c + Offset(x, y) * radius * persp * 1.1, (0.34 + 0.72 * depth * depth) * crowd, 0.2 + 0.8 * depth,
              depth, z > 0.72));
        }
      case PeopleLayout.orbit:
        const rings = [(100.0, 5, 0.0065), (162.0, 10, -0.0042), (226.0, 16, 0.0026)];
        var i = 0;
        for (final (ring, (r, n, speed)) in rings.indexed) {
          for (var j = 0; j < n && i < count; j++, i++) {
            final a = j * 2 * math.pi / n + _now * speed * 60 * (_still ? 0 : 1) +
                _spin * (ring == 1 ? -1 : 1) * (1.4 - ring * 0.3) + ring;
            final depth = (1 - math.cos(a)) / 2;
            out.add(_Target(
              c + Offset(r * k * math.sin(a), -r * k * 0.58 * math.cos(a)),
              (0.52 - ring * 0.1) + (0.4 - ring * 0.08) * depth,
              0.45 + 0.55 * depth,
              depth + 2 - ring * 0.3,
              depth > 0.85 && ring == 0,
            ));
          }
        }
      case PeopleLayout.magnifier:
        // The biggest cells that still fit everyone.
        var cell = 70.0 * k, cols = 5;
        while (cell > 30) {
          cols = math.max(1, ((w - 16) / cell).floor());
          if ((count / cols).ceil() * cell <= h - 24) break;
          cell -= 1;
        }
        final rows = (count / cols).ceil();
        final origin = c - Offset((cols - 1) * cell / 2, (rows - 1) * cell / 2);
        final base = cell / _size * 0.86;
        for (var i = 0; i < count; i++) {
          var p = origin + Offset((i % cols) * cell, (i ~/ cols) * cell);
          final away = p - _lens, d = away.distance;
          final f = _lensOn * math.max(0, 1 - d / (150 * k)), e = f * f * (3 - 2 * f);
          if (d > 0) p += away / d * 56 * k * e;
          out.add(_Target(p, base + 0.6 * e, 1, e, e > 0.85));
        }
      case PeopleLayout.carousel:
        final cols = _drumColumns, step = 2 * math.pi / cols;
        final radius = math.max(205 * k, cols * 120 * k / (2 * math.pi));
        for (var i = 0; i < count; i++) {
          final a = (i ~/ 3) * step + _drum, row = i % 3;
          final z = math.cos(a), depth = (z + 1) / 2;
          out.add(_Target(
            c + Offset(radius * math.sin(a), (row - 1) * 134 * k * (0.75 + 0.25 * depth)),
            0.38 + 0.62 * depth * depth,
            z < -0.25 ? 0 : 0.15 + 0.85 * depth,
            depth,
            z > 0.93,
          ));
        }
      default:
        break;
    }
    return out;
  }

  /// A hexagonal spiral out from the middle.
  static List<Offset> _hex(int count) {
    const gap = 100.0;
    const dirs = [Offset(-0.5, 0.866), Offset(-1, 0), Offset(-0.5, -0.866), Offset(0.5, -0.866), Offset(1, 0), Offset(0.5, 0.866)];
    final out = <Offset>[Offset.zero];
    for (var r = 1; out.length < count; r++) {
      var p = Offset(r * gap, 0);
      for (final d in dirs) {
        for (var s = 0; s < r; s++) {
          out.add(p);
          p += d * gap;
        }
      }
    }
    return out.take(count).toList();
  }

  void _panStart(DragStartDetails d) {
    _dragging = true;
    _panV = Offset.zero;
    _rotV = _yawV = _pitchV = _spinV = _drumV = 0;
    if (widget.layout == PeopleLayout.magnifier) {
      _lens = d.localPosition;
      _lensOn = 1;
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    final delta = d.delta, k = _area.width / 412;
    switch (widget.layout) {
      case PeopleLayout.honeycomb:
        _pan += delta;
        _panV = delta;
      case PeopleLayout.sunflower:
        // Spin by the angle the finger moves around the middle.
        final c = _area.center(Offset.zero);
        final before = d.localPosition - delta - c, after = d.localPosition - c;
        var da = after.direction - before.direction;
        if (da > math.pi) da -= 2 * math.pi;
        if (da < -math.pi) da += 2 * math.pi;
        _rot += da;
        _rotV = da;
      case PeopleLayout.globe:
        _yaw += delta.dx * 0.009;
        _pitch = (_pitch - delta.dy * 0.009).clamp(-1.1, 1.1);
        _yawV = delta.dx * 0.009;
        _pitchV = -delta.dy * 0.009;
      case PeopleLayout.orbit:
        _spin += delta.dx * 0.01;
        _spinV = delta.dx * 0.01;
      case PeopleLayout.magnifier:
        _lens = d.localPosition;
        _lensOn = 1;
      case PeopleLayout.carousel:
        _drum += delta.dx / (205 * k);
        _drumV = delta.dx / (205 * k);
      default:
        break;
    }
  }

  void _panEnd(DragEndDetails d) {
    _dragging = false;
    if (_still) _panV = Offset.zero;
  }

  /// The front-most face under the finger.
  void _tap(TapUpDetails d) {
    PersonSummary? hit;
    var best = -1.0;
    for (final p in _people.take(_cap)) {
      final n = _nodes[p.id], g = n?.target;
      if (n == null || g == null || n.opacity < 0.3) continue;
      if ((n.pos - d.localPosition).distance <= _half * n.scale && g.depth > best) {
        best = g.depth;
        hit = p;
      }
    }
    if (hit == null) return;
    Haptics.tick();
    widget.onOpen(hit);
  }

  String get _hint => switch (widget.layout) {
        PeopleLayout.honeycomb => 'Drag to look around',
        PeopleLayout.sunflower => 'Drag around the middle to spin',
        PeopleLayout.globe => 'Drag to roll the globe',
        PeopleLayout.orbit => 'Drag sideways to spin the rings',
        PeopleLayout.magnifier => 'Drag over the faces',
        PeopleLayout.carousel => 'Swipe sideways to spin',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Built once per rebuild, not per frame: frames only move them.
    final faces = {
      for (final p in _people)
        p.id: RepaintBoundary(
          child: Container(
            width: _size,
            height: _size,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.name == null ? scheme.onSurface.withAlpha(60) : scheme.primary,
            ),
            child: FaceAvatar(personId: p.id, thumb: p.coverThumb, radius: _half - 3),
          ),
        ),
    };
    final labels = {
      for (final p in _people)
        p.id: Text.rich(
          TextSpan(children: [
            TextSpan(
              text: p.name ?? 'Add a name',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.name == null ? scheme.primary : scheme.onSurface),
            ),
            TextSpan(
              text: '\n${p.photoCount} photos',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
            ),
          ]),
          textAlign: TextAlign.center,
          style: const TextStyle(shadows: [Shadow(color: Colors.black54, blurRadius: 6)]),
        ),
    };
    final bottom = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(builder: (context, box) {
      // The usable area stops above the floating dock.
      _area = Size(box.maxWidth, math.max(0, box.maxHeight - bottom));
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _panStart,
        onPanUpdate: _panUpdate,
        onPanEnd: _panEnd,
        onTapUp: _tap,
        child: ClipRect(
          child: ValueListenableBuilder<int>(
            valueListenable: _frame,
            builder: (context, _, _) {
              final shown = _people.take(_cap).where((p) => _nodes[p.id]?.target != null).toList()
                ..sort((a, b) => _nodes[a.id]!.target!.depth.compareTo(_nodes[b.id]!.target!.depth));
              final morphing = _now - _switchedAt < 0.5;
              final orbit = widget.layout == PeopleLayout.orbit;
              final c = _area.center(Offset.zero);
              final k = _area.width / 412;
              return Stack(clipBehavior: Clip.none, children: [
                if (orbit)
                  Positioned.fill(child: CustomPaint(painter: _RingsPainter(c, k, scheme.onSurface.withAlpha(22)))),
                if (orbit)
                  Positioned(
                    left: c.dx - 48,
                    top: c.dy - 48,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary,
                        boxShadow: [BoxShadow(color: scheme.primary.withAlpha(36), spreadRadius: 8)],
                      ),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(widget.hubLabel == null ? Icons.groups_rounded : Icons.luggage_rounded, color: scheme.onPrimary),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(widget.hubLabel ?? 'Everyone',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: scheme.onPrimary)),
                        ),
                      ]),
                    ),
                  ),
                if (widget.layout == PeopleLayout.magnifier && _lensOn > 0.02)
                  Positioned(
                    left: _lens.dx - 150 * k,
                    top: _lens.dy - 150 * k,
                    child: IgnorePointer(
                      child: Container(
                        width: 300 * k,
                        height: 300 * k,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.primary.withValues(alpha: 0.35 * _lensOn), width: 1.5),
                        ),
                      ),
                    ),
                  ),
                for (final p in shown)
                  _face(p, _nodes[p.id]!, faces[p.id]!, labels[p.id]!, !morphing),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: IgnorePointer(
                    child: Text(_hint,
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  ),
                ),
              ]);
            },
          ),
        ),
      );
    });
  }

  Widget _face(PersonSummary p, _Node n, Widget face, Widget label, bool labels) {
    return Positioned(
      key: ValueKey(p.id),
      left: n.pos.dx - _half,
      top: n.pos.dy - _half,
      width: _size,
      height: _size,
      child: IgnorePointer(
        child: Transform.scale(
          scale: n.scale,
          child: Opacity(
            opacity: n.opacity.clamp(0.0, 1.0),
            child: Stack(clipBehavior: Clip.none, children: [
              face,
              Positioned(
                left: -40,
                right: -40,
                top: _size + 5,
                child: AnimatedOpacity(
                  opacity: labels && (n.target?.label ?? false) ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: label,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The Orbit's tilted rings.
class _RingsPainter extends CustomPainter {
  _RingsPainter(this.centre, this.k, this.color);

  final Offset centre;
  final double k;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final r in const [100.0, 162.0, 226.0]) {
      canvas.drawOval(Rect.fromCenter(center: centre, width: r * k * 2, height: r * k * 0.58 * 2), paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.centre != centre || old.k != k || old.color != color;
}
