import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../share/protocol.dart';
import '../share/send_center.dart';
import 'island.dart';
import 'motion.dart';
import 'sections.dart';

/// A device you can send to: found on Wi-Fi (LocalSend), remembered from
/// before, or found over Nearby (no network).
class Target {
  Target.lan(LsDevice this.device, {this.saved})
      : nearbyName = null,
        online = true;
  Target.saved(SavedDevice this.saved, LsDevice this.device, {required this.online}) : nearbyName = null;
  Target.nearby(String this.nearbyName)
      : device = null,
        saved = null,
        online = true;

  final LsDevice? device;
  final SavedDevice? saved;
  final String? nearbyName;
  final bool online;

  String get name => nearbyName ?? device!.alias;
  bool get favourite => saved?.favorite ?? false;
  String get key => nearbyName != null ? 'nearby:$nearbyName' : device!.fingerprint;

  IconData get icon {
    if (nearbyName != null) return Icons.bluetooth_connected_rounded;
    final type = device?.info.deviceType.name ?? saved?.type;
    return switch (type) {
      'desktop' => Icons.computer_rounded,
      'web' => Icons.public_rounded,
      'server' || 'headless' => Icons.dns_rounded,
      _ => Icons.smartphone_rounded,
    };
  }

  String get subtitle {
    if (nearbyName != null) return 'Nearby · no network needed';
    final model = device?.info.deviceModel ?? saved?.model;
    return [
      ?model,
      if (!online) 'not seen now' else device!.ip,
    ].join(' · ');
  }

  /// One short line for the orbit: the model, "Nearby" or "Not seen now".
  String get shortSubtitle {
    if (nearbyName != null) return 'Nearby';
    if (!online) return 'Not seen now';
    return device?.info.deviceModel ?? saved?.model ?? device!.ip;
  }
}

/// A stand-in for a remembered device that isn't announcing right now; a
/// send to it waits until it shows up.
LsDevice deviceFor(SendCenter s, SavedDevice d) =>
    s.discovery.byFingerprint(d.fingerprint) ??
    LsDevice(
      info: LsInfo(
        alias: d.alias,
        fingerprint: d.fingerprint,
        deviceModel: d.model,
        port: d.port ?? lsPort,
        protocol: d.protocol ?? 'https',
      ),
      ip: d.ip ?? '',
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );

/// A flat colour that tells devices apart at a glance; the same device
/// always gets the same one.
Color deviceColor(String key) {
  const colors = [
    Color(0xFFE0684E),
    Color(0xFF6E5BFF),
    Color(0xFF1F9E92),
    Color(0xFFD9822B),
    Color(0xFFB04FA8),
    Color(0xFF34A86A),
  ];
  final h = key.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
  return colors[h % colors.length];
}

const _online = Color(0xFF30D158);

// ---------------------------------------------------------------------------
// The orbit: you in the middle, devices around you on tilted rings.

/// One device on the [Orbit].
class OrbitNode {
  const OrbitNode({
    required this.key,
    required this.name,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.ring = 1,
    this.angle,
    this.online = true,
    this.favourite = false,
    this.progress,
    this.done = false,
    this.status = false,
    this.flowing = false,
  });

  final String key, name, subtitle;
  final IconData icon;
  final Color color;

  /// 0: favourites (inner), 1: online (middle), 2: not seen now (outer).
  final int ring;

  /// Degrees clockwise from the top; spread evenly around the ring if null.
  final double? angle;
  final bool online, favourite;

  /// A ring around the bubble: null for none, negative while waiting,
  /// otherwise 0 to 1.
  final double? progress;

  /// Just finished: a tick over the bubble.
  final bool done;

  /// The subtitle is a live status, shown in the accent colour.
  final bool status;

  /// The line to this device streams (a transfer is running).
  final bool flowing;
}

/// Where a node sits on the orbit.
class _Spot {
  const _Spot(this.node, this.pos, this.deg, this.depth);

  final OrbitNode node;
  final Offset pos;
  final double deg, depth;
}

/// Nearby devices around you: tilted rings with a radar sweep that pings
/// each device as it passes, lines from you to each device, and a glowing
/// centre that can be dragged onto a device.
class Orbit extends StatefulWidget {
  const Orbit({
    super.key,
    required this.nodes,
    required this.centre,
    this.centreSize = 84,
    this.height = 352,
    this.centreY = 162,
    this.armed = false,
    this.scanning = true,
    this.inflow = false,
    this.centreLabel,
    this.emptyText,
    this.dragFeedback,
    this.onCentreTap,
    this.onTap,
    this.onLongPress,
    this.onDrop,
  });

  final List<OrbitNode> nodes;
  final Widget centre;
  final double centreSize, height, centreY;

  /// Something is ready to send: lines flow, devices breathe, the centre
  /// pulses.
  final bool armed;

  /// The radar sweep and ripples run.
  final bool scanning;

  /// Streams flow towards the centre (receiving) instead of away from it.
  final bool inflow;
  final String? centreLabel;

  /// Shown at the bottom when there are no devices.
  final String? emptyText;

  /// Shown under the finger while dragging the centre; null means the
  /// centre can't be dragged.
  final Widget? dragFeedback;
  final VoidCallback? onCentreTap;

  /// [bubble] is the device bubble's global rect, for animations.
  final void Function(OrbitNode node, Rect? bubble)? onTap, onLongPress, onDrop;

  @override
  State<Orbit> createState() => _OrbitState();
}

/// What a dragged centre carries.
const _orbitDrag = 'orbit-send';

class _OrbitState extends State<Orbit> with SingleTickerProviderStateMixin {
  // One 12 s loop drives everything: the sweep (4 s), ripples (4 s), the
  // breathing (2 s), the floating (6 s) and the flowing lines.
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(seconds: 12));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _t
        ..stop()
        ..value = 0.3;
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// Spreads each ring's devices evenly and turns the rings so bubbles and
  /// labels stay clear of each other, of you, and of the card's edges.
  List<_Spot> _layout(Offset c, List<double> radii, double width) {
    final rings = [
      for (var r = 0; r < 3; r++) [for (final n in widget.nodes) if (n.ring == r) n],
    ];
    Offset at(int ring, double deg) {
      final a = deg * math.pi / 180;
      return Offset(c.dx + radii[ring] * math.sin(a), c.dy - radii[ring] * 0.7 * math.cos(a));
    }

    List<double> degrees(int ring, double offset) => [
          for (final (i, n) in rings[ring].indexed) n.angle ?? (offset + i * 360 / rings[ring].length) % 360,
        ];

    // 1 or more means no two devices (bubble plus label) touch.
    double score(List<double> offsets) {
      final pts = [
        for (var r = 0; r < 3; r++)
          for (final d in degrees(r, offsets[r])) at(r, d),
      ];
      var best = double.infinity;
      for (final (i, p) in pts.indexed) {
        for (final (j, o) in [c, ...pts].indexed) {
          if (j == i + 1) continue;
          best = math.min(best, math.max((p.dx - o.dx).abs() / 124, (p.dy - o.dy).abs() / 92));
        }
        final side = math.min(p.dx - 58, width - 58 - p.dx);
        if (side < 0) best = math.min(best, 0.5 + side / 100);
        final bottom = widget.height - (p.dy + 68);
        if (bottom < 0) best = math.min(best, 0.5 + bottom / 100);
      }
      return best;
    }

    // Turn one ring at a time for a few rounds; the preferred turns win ties
    // so layouts stay put.
    final offsets = [66.0, 310.0, 218.0];
    var current = score(offsets);
    for (var round = 0; round < 3; round++) {
      for (var r = 0; r < 3; r++) {
        if (rings[r].isEmpty) continue;
        final start = offsets[r];
        for (var k = 1; k < 36; k++) {
          final trial = [...offsets]..[r] = (start + k * 10) % 360;
          final s = score(trial);
          if (s > current + 0.02) {
            offsets[r] = trial[r];
            current = s;
          }
        }
      }
    }
    return [
      for (var r = 0; r < 3; r++)
        for (final (i, deg) in degrees(r, offsets[r]).indexed)
          // Devices at the front of the tilted plane sit a little larger.
          _Spot(rings[r][i], at(r, deg), deg, 0.86 + 0.2 * (1 - math.cos(deg * math.pi / 180)) / 2),
    ];
  }

  Widget _centre() {
    final core = widget.centre;
    Widget child = core;
    if (widget.armed) {
      child = AnimatedBuilder(
        animation: _t,
        builder: (context, c) => Transform.scale(scale: 1.025 + 0.025 * math.sin(_t.value * 12 * math.pi), child: c),
        child: core,
      );
    }
    child = GestureDetector(onTap: widget.onCentreTap, child: child);
    final feedback = widget.dragFeedback;
    if (feedback == null) return child;
    return Draggable<String>(
      data: _orbitDrag,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(offset: const Offset(-32, -32), child: feedback),
      childWhenDragging: Opacity(opacity: 0.25, child: core),
      onDragStarted: Haptics.lift,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final c = Offset(w / 2, widget.centreY);
        final radii = [for (final f in const [0.263, 0.395, 0.526]) w * f];
        final spots = _layout(c, radii, w);
        final half = widget.centreSize / 2;
        return Stack(clipBehavior: Clip.hardEdge, children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _OrbitPainter(
                  t: _t,
                  centre: c,
                  radii: radii,
                  spots: spots,
                  color: scheme.primary,
                  line: (dark ? Colors.white : Colors.black).withAlpha(dark ? 20 : 18),
                  armed: widget.armed,
                  scanning: widget.scanning,
                  inflow: widget.inflow,
                  coreRadius: half,
                ),
              ),
            ),
          ),
          Positioned(left: c.dx - half, top: c.dy - half, width: widget.centreSize, height: widget.centreSize, child: _centre()),
          if (widget.centreLabel != null)
            Positioned(
              left: c.dx - 60,
              width: 120,
              top: c.dy + half + 6,
              child: Text(widget.centreLabel!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
            ),
          for (final s in spots)
            AnimatedPositioned(
              key: ValueKey(s.node.key),
              duration: 500.ms,
              curve: Curves.easeOutCubic,
              left: s.pos.dx - 64,
              top: s.pos.dy - 28,
              width: 128,
              child: _NodeView(
                spot: s,
                t: _t,
                armed: widget.armed,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                onDrop: widget.onDrop,
              ),
            ),
          if (widget.emptyText != null && !widget.nodes.any((n) => n.online))
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Text(widget.emptyText!,
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
        ]);
      }),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({
    required this.t,
    required this.centre,
    required this.radii,
    required this.spots,
    required this.color,
    required this.line,
    required this.armed,
    required this.scanning,
    required this.inflow,
    required this.coreRadius,
  }) : super(repaint: t);

  final Animation<double> t;
  final Offset centre;
  final List<double> radii;
  final List<_Spot> spots;
  final Color color, line;
  final bool armed, scanning, inflow;
  final double coreRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = line;

    // Rings, sweep and ripples lie on a plane tilted away from you.
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(1, 0.7);
    canvas.drawCircle(Offset.zero, radii[0], stroke);
    canvas.drawCircle(Offset.zero, radii[1], stroke);
    _dashedCircle(canvas, radii[2], stroke, 0);
    if (scanning) {
      // Clockwise from the top, like the pings on the devices.
      final sweep = (v * 3 % 1) * 2 * math.pi;
      canvas.drawLine(
        Offset(coreRadius * math.sin(sweep), -coreRadius * math.cos(sweep)),
        Offset(radii[2] * math.sin(sweep), -radii[2] * math.cos(sweep)),
        Paint()
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = color.withAlpha(150),
      );
      for (var k = 0; k < 3; k++) {
        final p = (v * 3 + k / 3) % 1;
        canvas.drawCircle(
          Offset.zero,
          coreRadius * (1 + 3.8 * p),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color.withValues(alpha: 0.6 * (1 - p)),
        );
      }
    }
    canvas.restore();

    // A gently curved line from you to each device.
    for (final s in spots) {
      final p = s.pos, d = p - centre;
      final ctrl = Offset((centre.dx + p.dx) / 2 + d.dy * 0.2, (centre.dy + p.dy) / 2 - d.dx * 0.2);
      final path = Path()
        ..moveTo(centre.dx, centre.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, p.dx, p.dy);
      final n = s.node;
      if (n.flowing) {
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = color.withAlpha(60),
        );
        _dash(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = color,
          (inflow ? -1 : 1) * v * 12 * 44,
          gap: 8,
        );
      } else if (armed && n.online) {
        _dash(
          canvas,
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeCap = StrokeCap.round
            ..color = color.withAlpha(180),
          v * 12 * 20,
        );
      } else {
        canvas.drawPath(path, stroke..strokeWidth = 1.5);
      }
    }

    // A slowly turning dashed halo says "drag me".
    if (armed) {
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      _dashedCircle(
        canvas,
        coreRadius + 11,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withAlpha(180),
        v * 2 * math.pi,
        segments: 36,
      );
      canvas.restore();
    }
  }

  void _dashedCircle(Canvas canvas, double r, Paint paint, double rotation, {int segments = 72}) {
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final step = 2 * math.pi / segments;
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(rect, rotation + i * step, step * 0.55, false, paint);
    }
  }

  void _dash(Canvas canvas, Path path, Paint paint, double phase, {double on = 2, double gap = 9}) {
    final period = on + gap;
    for (final m in path.computeMetrics()) {
      for (var d = phase % period - period; d < m.length; d += period) {
        final a = math.max(0.0, d), b = math.min(m.length, d + on);
        if (b > a) canvas.drawPath(m.extractPath(a, b), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => true;
}

class _NodeView extends StatefulWidget {
  const _NodeView({required this.spot, required this.t, required this.armed, this.onTap, this.onLongPress, this.onDrop});

  final _Spot spot;
  final Animation<double> t;
  final bool armed;
  final void Function(OrbitNode node, Rect? bubble)? onTap, onLongPress, onDrop;

  @override
  State<_NodeView> createState() => _NodeViewState();
}

class _NodeViewState extends State<_NodeView> {
  final _bubble = GlobalKey();
  bool _hover = false;

  Rect? get _rect {
    final box = _bubble.currentContext?.findRenderObject() as RenderBox?;
    return box == null || !box.attached ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.spot.node;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final seed = (n.key.hashCode % 97) / 97;
    final idle = n.progress == null && !n.done;

    final bubble = AnimatedBuilder(
      animation: widget.t,
      builder: (context, child) {
        final v = widget.t.value;
        // The sweep lights a device up as it passes, then the glow fades.
        final sweep = (v * 3 % 1) * 360;
        final since = (sweep - widget.spot.deg) % 360;
        final ping = n.online && idle ? math.max(0.0, 1 - since / 80) : 0.0;
        final breathe = widget.armed && n.online && idle ? 0.5 + 0.5 * math.sin(v * 12 * math.pi) : -1.0;
        final bob = -2.5 - 2.5 * math.sin((v * 2 + seed) * 2 * math.pi);
        return Transform.translate(
          offset: Offset(0, bob),
          child: CustomPaint(foregroundPainter: _HaloPainter(ping, breathe, _hover, scheme.primary), child: child),
        );
      },
      child: OrbitBubble(key: _bubble, node: n, hover: _hover),
    );

    final label = Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(9, 3, 9, 4),
      decoration: BoxDecoration(
        color: dark ? Colors.black.withAlpha(102) : Colors.white.withAlpha(180),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(n.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: n.online ? scheme.onSurface : scheme.onSurfaceVariant,
            )),
        Text(n.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: n.status ? FontWeight.w600 : FontWeight.w400,
              color: n.status ? scheme.primary : scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ]),
    );

    // Loose width, so only the bubble and label take touches, not the
    // whole slot.
    return Align(
      alignment: Alignment.topCenter,
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) {
          if (d.data != _orbitDrag) return false;
          Haptics.tick();
          setState(() => _hover = true);
          return true;
        },
        onLeave: (_) => setState(() => _hover = false),
        onAcceptWithDetails: (_) {
          setState(() => _hover = false);
          widget.onDrop?.call(n, _rect);
        },
        builder: (context, _, _) => Semantics(
          button: true,
          label: '${n.name}, ${n.subtitle}',
          child: Transform.scale(
            scale: widget.spot.depth,
            child: Pressable(
              onTap: widget.onTap == null ? null : () => widget.onTap!(n, _rect),
              onLongPress: widget.onLongPress == null
                  ? null
                  : () {
                      Haptics.lift();
                      widget.onLongPress!(n, _rect);
                    },
              child: Column(mainAxisSize: MainAxisSize.min, children: [bubble, label]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The ping from the sweep, the "ready" breathing ring and the drop-target
/// ring, drawn around a bubble.
class _HaloPainter extends CustomPainter {
  _HaloPainter(this.ping, this.breathe, this.hover, this.color);

  final double ping, breathe;
  final bool hover;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    if (ping > 0) {
      canvas.drawCircle(
        c,
        r + 4 + 6 * (1 - ping),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: 0.9 * ping),
      );
    }
    if (hover || breathe >= 0) {
      canvas.drawCircle(
        c,
        hover ? r + 9 : r + 6 + 4 * breathe,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: hover ? 1 : 0.85 - 0.55 * breathe),
      );
    }
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.ping != ping || old.breathe != breathe || old.hover != hover || old.color != color;
}

/// A device's round bubble: its colour and symbol, an online dot, a star for
/// favourites, and a progress ring or tick while sending.
class OrbitBubble extends StatelessWidget {
  const OrbitBubble({super.key, required this.node, this.hover = false});

  final OrbitNode node;
  final bool hover;

  @override
  Widget build(BuildContext context) {
    final n = node;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rim = dark ? const Color(0xFF141416) : Colors.white;
    return AnimatedScale(
      scale: hover ? 1.2 : 1,
      duration: 260.ms,
      curve: Curves.easeOutBack,
      child: SizedBox.square(
        dimension: 56,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: n.online ? n.color : (dark ? const Color(0xFF3A3A40) : const Color(0xFFD1D1D6)),
              ),
              child: Icon(n.icon, size: 24, color: n.online ? Colors.white : (dark ? Colors.white54 : Colors.black38)),
            ),
          ),
          if (n.progress != null)
            Positioned(
              left: -8,
              top: -8,
              right: -8,
              bottom: -8,
              child: n.progress! < 0
                  ? CircularProgressIndicator(
                      strokeWidth: 3.5,
                      strokeCap: StrokeCap.round,
                      color: scheme.primary,
                      backgroundColor: scheme.onSurface.withAlpha(30),
                    )
                  : TweenAnimationBuilder<double>(
                      tween: Tween(end: n.progress),
                      duration: 250.ms,
                      builder: (context, v, _) => CircularProgressIndicator(
                        value: v,
                        strokeWidth: 3.5,
                        strokeCap: StrokeCap.round,
                        color: scheme.primary,
                        backgroundColor: scheme.onSurface.withAlpha(30),
                      ),
                    ),
            ),
          Positioned(
            right: 1,
            bottom: 1,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: n.online ? _online : const Color(0xFF8E8E93),
                shape: BoxShape.circle,
                border: Border.all(color: rim, width: 2.5),
              ),
            ),
          ),
          if (n.favourite)
            Positioned(
              right: -5,
              top: -4,
              child: Container(
                width: 21,
                height: 21,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD60A),
                  shape: BoxShape.circle,
                  border: Border.all(color: rim, width: 2.5),
                ),
                child: const Icon(Icons.star_rounded, size: 12, color: Color(0xFF3D2E00)),
              ),
            ),
          if (n.done)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary.withAlpha(235)),
                child: Icon(Icons.check_rounded, size: 28, color: scheme.onPrimary),
              ).animate().fadeIn(duration: 200.ms).scaleXY(begin: 0.6, curve: Curves.easeOutBack),
            ),
        ]),
      ),
    );
  }
}

/// The glowing orb in the middle of the orbit, in the accent colour; [idle]
/// makes it a quiet grey.
class OrbitCore extends StatelessWidget {
  const OrbitCore({super.key, required this.child, this.size = 84, this.idle = false});

  final Widget child;
  final double size;
  final bool idle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = scheme.primary;
    return AnimatedContainer(
      duration: 500.ms,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: idle ? (dark ? const Color(0xFF2C2C30) : const Color(0xFFE9E9EE)) : p,
        border: idle ? Border.all(color: scheme.onSurface.withAlpha(24)) : null,
        boxShadow: idle ? null : [BoxShadow(color: p.withAlpha(36), spreadRadius: 7)],
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: idle ? scheme.onSurfaceVariant : scheme.onPrimary, fontWeight: FontWeight.w800),
        child: IconTheme(
          data: IconThemeData(color: idle ? scheme.onSurfaceVariant : scheme.onPrimary),
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// The receive orb filling up like a glass of water as files arrive.
class OrbitTank extends StatefulWidget {
  const OrbitTank({super.key, required this.progress, required this.child, this.size = 96});

  final double progress;
  final Widget child;
  final double size;

  @override
  State<OrbitTank> createState() => _OrbitTankState();
}

class _OrbitTankState extends State<OrbitTank> with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _wave.stop();
    } else if (!_wave.isAnimating) {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final p = scheme.primary;
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dark ? const Color(0xFF242428) : const Color(0xFFF2F2F5),
        border: Border.all(color: p.withAlpha(150), width: 1.5),
        boxShadow: [BoxShadow(color: p.withAlpha(40), spreadRadius: 7)],
      ),
      child: ClipOval(
        child: Stack(fit: StackFit.expand, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: widget.progress.clamp(0, 1)),
            duration: 300.ms,
            builder: (context, level, _) => CustomPaint(
              painter: _WavePainter(_wave, level, p),
            ),
          ),
          Center(
            child: DefaultTextStyle(
              style: TextStyle(
                color: dark ? Colors.white : Colors.black,
                fontSize: 21,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
                shadows: [Shadow(color: (dark ? Colors.black : Colors.white).withAlpha(110), blurRadius: 6)],
              ),
              child: IconTheme(data: IconThemeData(color: dark ? Colors.white : Colors.black), child: widget.child),
            ),
          ),
        ]),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.phase, this.level, this.color) : super(repaint: phase);

  final Animation<double> phase;
  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0) return;
    final y0 = size.height * (1 - level);
    final amp = level >= 1 ? 0.0 : 3.0;
    final path = Path()..moveTo(0, y0);
    for (var x = 0.0; x <= size.width; x += 2) {
      path.lineTo(x, y0 + amp * math.sin((x / size.width * 2 + phase.value) * 2 * math.pi));
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.level != level || old.color != color;
}

// ---------------------------------------------------------------------------
// Flourishes.

/// A paper plane takes off from [from] (global position) and flies up and
/// away, as a "sent!" flourish.
void flyPaperPlane(BuildContext context, Offset from) {
  if (MediaQuery.disableAnimationsOf(context)) return;
  final overlay = Overlay.of(context);
  final color = Theme.of(context).colorScheme.primary;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        onEnd: entry.remove,
        builder: (context, t, _) {
          // A gentle arc up and to the right, growing then fading out.
          final e = Curves.easeInCubic.transform(t);
          final pos = from + Offset(220 * e, -60 * t - 380 * e * e);
          return Stack(children: [
            Positioned(
              left: pos.dx - 16,
              top: pos.dy - 16,
              child: Opacity(
                opacity: (1 - t * t).clamp(0, 1),
                child: Transform.rotate(
                  angle: -0.5 - 0.4 * e,
                  child: Transform.scale(
                    scale: 1 + 0.8 * math.sin(t * math.pi),
                    child: Icon(Icons.send_rounded, size: 32, color: color),
                  ),
                ),
              ),
            ),
          ]);
        },
      ),
    ),
  );
  overlay.insert(entry);
}

/// [orb] arcs from [from] to [to] (global rects), shrinking as it lands.
Future<void> flyOrb(BuildContext context, Rect from, Rect to, Widget orb) {
  final done = Completer<void>();
  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeInOutCubic,
        onEnd: () {
          entry.remove();
          done.complete();
        },
        builder: (context, t, child) {
          final c = Offset.lerp(from.center, to.center, t)! + Offset(0, -50 * math.sin(t * math.pi));
          return Stack(children: [
            Positioned(
              left: c.dx - 32,
              top: c.dy - 32,
              child: Opacity(opacity: 1 - 0.6 * t, child: Transform.scale(scale: 1 - 0.75 * t, child: child)),
            ),
          ]);
        },
        child: SizedBox.square(dimension: 64, child: orb),
      ),
    ),
  );
  overlay.insert(entry);
  return done.future;
}

class _MenuAction {
  const _MenuAction(this.label, this.icon, [this.onTap]);

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
}

/// Touch and hold: the page blurs, the device lifts, and a short menu
/// appears next to it.
Future<void> _showDeviceMenu(
  BuildContext context, {
  required Rect anchor,
  required Widget preview,
  required String caption,
  required List<_MenuAction> actions,
}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, a, _) {
      final size = MediaQuery.sizeOf(context);
      final scheme = Theme.of(context).colorScheme;
      final dark = Theme.of(context).brightness == Brightness.dark;
      const menuWidth = 250.0;
      final below = anchor.center.dy < size.height * 0.6;
      final left = (anchor.center.dx - menuWidth / 2).clamp(16.0, size.width - menuWidth - 16);
      final pop = CurvedAnimation(parent: a, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: AnimatedBuilder(
              animation: a,
              builder: (context, _) => BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14 * a.value, sigmaY: 14 * a.value),
                child: ColoredBox(color: Colors.black.withValues(alpha: (dark ? 0.4 : 0.18) * a.value)),
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: anchor,
          child: IgnorePointer(child: ScaleTransition(scale: Tween(begin: 1.0, end: 1.12).animate(pop), child: preview)),
        ),
        Positioned(
          left: left,
          width: menuWidth,
          top: below ? anchor.bottom + 56 : null,
          bottom: below ? null : size.height - anchor.top + 18,
          child: FadeTransition(
            opacity: a,
            child: ScaleTransition(
              alignment: below ? Alignment.topCenter : Alignment.bottomCenter,
              scale: Tween(begin: 0.6, end: 1.0).animate(pop),
              child: Material(
                color: dark ? const Color(0xF22C2C2E) : const Color(0xF7F9F9F9),
                elevation: 12,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                    child: Text(caption,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  ),
                  for (final m in actions) ...[
                    const Divider(height: 0.5, thickness: 0.5),
                    InkWell(
                      onTap: m.onTap == null
                          ? null
                          : () {
                              Navigator.pop(context);
                              m.onTap!();
                            },
                      child: SizedBox(
                        height: 46,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            Expanded(
                              child: Text(m.label,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: m.onTap == null ? scheme.onSurfaceVariant.withAlpha(130) : scheme.onSurface,
                                  )),
                            ),
                            Icon(m.icon,
                                size: 20, color: m.onTap == null ? scheme.onSurfaceVariant.withAlpha(130) : scheme.onSurface),
                          ]),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]);
    },
  ));
}

// ---------------------------------------------------------------------------

/// Nearby devices on an [Orbit]: favourites on the inner ring, everything
/// else that's online (Wi-Fi and Nearby) in the middle, remembered devices
/// that aren't around on the outside. Tap a device (or drag the centre onto
/// it) to send; touch and hold for more.
class DevicePicker extends StatefulWidget {
  const DevicePicker({super.key, required this.sharing, required this.onPick, this.count = 0, this.onOpenJob});

  final SendCenter sharing;

  /// Called once the send flourish has landed on the device.
  final ValueChanged<Target> onPick;

  /// How many things are ready to send; 0 means nothing is picked yet.
  final int count;

  /// Tapping a device that has a send under way opens it here.
  final ValueChanged<SendJob>? onOpenJob;

  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  SendCenter get s => widget.sharing;
  List<SavedDevice> _saved = const [];
  final _centreKey = GlobalKey();

  /// When each send finished, so the bubble shows a tick for a moment.
  final Map<int, DateTime> _doneAt = {};
  bool _launching = false;

  static const _sentFor = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    s.open();
    _load();
    // Sends that finished before the picker opened don't flash "Sent".
    for (final j in s.jobs.where((j) => j.status == JobStatus.done)) {
      _doneAt[j.id] = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  @override
  void dispose() {
    s.close();
    if (!s.jobs.any((j) => j.nearby && !j.finished)) s.nearby.stopDiscovery();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await s.db.savedDevices();
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _toggleFavourite(Target t) async {
    final d = t.device;
    if (d == null) return;
    Haptics.lift();
    if (t.saved == null) {
      await s.db.saveDevice(
        fingerprint: d.fingerprint,
        alias: d.alias,
        model: d.info.deviceModel,
        type: d.info.deviceType.name,
        ip: d.ip,
        port: d.info.port,
        protocol: d.info.protocol,
      );
    }
    await s.db.setFavoriteDevice(d.fingerprint, !t.favourite);
    await _load();
    if (!mounted) return;
    Island.toast(t.favourite ? 'Removed from favourites' : '${t.name} is a favourite',
        icon: t.favourite ? Icons.star_outline_rounded : Icons.star_rounded);
  }

  Future<void> _enterAddress() async {
    final text = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect by address'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('The other device shows its address on its Receive screen (LocalSend: Settings › Network).'),
          const SizedBox(height: 12),
          TextField(
            controller: text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: '192.168.1.23'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: const Text('Connect')),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    final parts = ip.split(':');
    final found = await s.discovery.probe(parts.first, port: int.tryParse(parts.length > 1 ? parts[1] : '') ?? lsPort);
    if (!mounted) return;
    if (found == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Nothing answered at $ip. Is LocalSend or ShareBro open there?')));
    }
  }

  List<Target> _targets() {
    final out = <Target>[];
    final seen = <String>{};
    final savedBy = {for (final d in _saved) d.fingerprint: d};
    // Favourites first (even when they're not around right now).
    for (final d in _saved.where((d) => d.favorite)) {
      final live = s.discovery.byFingerprint(d.fingerprint);
      out.add(Target.saved(d, live ?? deviceFor(s, d), online: live != null));
      seen.add(d.fingerprint);
    }
    for (final d in s.discovery.devices) {
      if (seen.add(d.fingerprint)) out.add(Target.lan(d, saved: savedBy[d.fingerprint]));
    }
    for (final name in s.nearby.endpoints.values.toSet()) {
      out.add(Target.nearby(name));
    }
    // Then recent devices that aren't here now.
    for (final d in _saved.take(6)) {
      if (seen.add(d.fingerprint)) out.add(Target.saved(d, deviceFor(s, d), online: false));
    }
    return out;
  }

  SendJob? _jobFor(Target t) {
    for (final j in s.jobs.reversed) {
      if (j.fingerprint == t.key) return j;
    }
    return null;
  }

  OrbitNode _node(Target t, int ring) {
    var sub = t.shortSubtitle;
    double? progress;
    var status = false, done = false, flowing = false;
    final j = _jobFor(t);
    if (j != null && j.status != JobStatus.cancelled) {
      if (j.status == JobStatus.done) {
        if (!_doneAt.containsKey(j.id)) {
          _doneAt[j.id] = DateTime.now();
          // Clear the tick once its moment has passed.
          Timer(_sentFor, () {
            if (mounted) setState(() {});
          });
        }
        if (DateTime.now().difference(_doneAt[j.id]!) < _sentFor) {
          done = true;
          status = true;
          sub = 'Sent';
        }
      } else {
        status = true;
        switch (j.status) {
          case JobStatus.waiting:
            progress = -1;
            sub = t.online ? 'Waiting…' : 'Waiting for device';
          case JobStatus.preparing:
            progress = -1;
            sub = 'Getting ready…';
          case JobStatus.asking:
            progress = -1;
            sub = 'Waiting to accept…';
          case JobStatus.sending:
            progress = j.progress;
            flowing = true;
            sub = 'Sending ${(j.progress * 100).round()}%';
          case JobStatus.needsPin:
            sub = 'Needs a PIN';
          case JobStatus.declined:
            sub = 'Declined';
          case JobStatus.failed:
            sub = "Didn't send";
          case JobStatus.done || JobStatus.cancelled:
            break;
        }
      }
    }
    return OrbitNode(
      key: t.key,
      name: t.name,
      subtitle: sub,
      icon: t.icon,
      color: deviceColor(t.key),
      ring: ring,
      online: t.online,
      favourite: t.favourite,
      progress: progress,
      done: done,
      status: status,
      flowing: flowing,
    );
  }

  Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    return box == null || !box.attached ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  Widget _orb(double size) {
    final n = widget.count;
    return OrbitCore(
      size: size,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$n', style: TextStyle(fontSize: size * 0.36, height: 1, letterSpacing: -1)),
        Opacity(
          opacity: 0.72,
          child: Text(n == 1 ? 'ITEM' : 'ITEMS',
              style: TextStyle(fontSize: size * 0.12, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
        ),
      ]),
    );
  }

  /// Sends to [t] with the flourish: the orb flies over (unless it was
  /// dropped there), then a paper plane takes off.
  Future<void> _launch(Target t, Rect? bubble, {bool dropped = false}) async {
    if (_launching) return;
    _launching = true;
    try {
      final from = _rectOf(_centreKey);
      if (!dropped && from != null && bubble != null && !MediaQuery.disableAnimationsOf(context)) {
        await flyOrb(context, from, bubble, _orb(64));
      }
      if (!mounted) return;
      if (bubble != null) flyPaperPlane(context, bubble.center);
      widget.onPick(t);
    } finally {
      _launching = false;
    }
  }

  void _tap(Target t, Rect? bubble) {
    if (widget.count > 0) {
      _launch(t, bubble);
      return;
    }
    final j = _jobFor(t);
    if (j != null && !j.finished && widget.onOpenJob != null) {
      widget.onOpenJob!(j);
      return;
    }
    Haptics.warn();
    Island.toast('Pick something to send first', icon: Icons.touch_app_rounded);
  }

  void _menu(Target t, OrbitNode n, Rect? bubble) {
    if (bubble == null) return;
    final ip = t.device?.ip ?? '';
    final count = widget.count;
    _showDeviceMenu(
      context,
      anchor: bubble,
      preview: OrbitBubble(node: n),
      caption: t.nearbyName != null
          ? '${t.name} · Nearby, no network needed'
          : t.online && ip.isNotEmpty
              ? '${t.name} · $ip'
              : '${t.name} · not seen now',
      actions: [
        if (count > 0) _MenuAction('Send $count ${count == 1 ? 'item' : 'items'}', Icons.send_rounded, () => _launch(t, bubble)),
        if (t.device != null)
          _MenuAction(t.favourite ? 'Remove from favourites' : 'Add to favourites',
              t.favourite ? Icons.star_outline_rounded : Icons.star_rounded, () => _toggleFavourite(t))
        else
          const _MenuAction('Nearby phones can\'t be favourites', Icons.bluetooth_rounded),
        if (ip.isNotEmpty)
          _MenuAction('Copy address', Icons.copy_rounded, () {
            Clipboard.setData(ClipboardData(text: ip));
            Island.toast('Copied $ip', icon: Icons.copy_rounded);
          }),
      ],
    );
  }

  Widget _more() {
    return PopupMenuButton<int>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz_rounded, color: Theme.of(context).colorScheme.primary),
      style: IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.onSurface.withAlpha(20)),
      onSelected: (v) {
        if (v == 0) {
          s.discovery.scanSubnet();
        } else if (v == 1) {
          s.nearby.discovering ? s.nearby.stopDiscovery() : s.nearby.startDiscovery();
        } else {
          _enterAddress();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 0,
          enabled: !s.discovery.scanning,
          child: const ListTile(leading: Icon(Icons.refresh_rounded), title: Text('Scan again')),
        ),
        CheckedPopupMenuItem(value: 1, checked: s.nearby.discovering, child: const Text('Find phones without Wi‑Fi')),
        const PopupMenuItem(
          value: 2,
          child: ListTile(leading: Icon(Icons.dialpad_rounded), title: Text('Connect by address…')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.discovery, s.nearby]),
      builder: (context, _) {
        final targets = _targets();
        final byKey = {for (final t in targets) t.key: t};
        // A few per ring keep the orbit readable; the rest go in a row below.
        const cap = [2, 4, 2];
        final perRing = [0, 0, 0];
        final nodes = <OrbitNode>[];
        final extra = <Target>[];
        for (final t in targets) {
          final ring = t.favourite ? 0 : t.online ? 1 : 2;
          if (perRing[ring] >= cap[ring]) {
            extra.add(t);
            continue;
          }
          perRing[ring]++;
          nodes.add(_node(t, ring));
        }
        final anyOnline = targets.any((t) => t.online);
        final armed = widget.count > 0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(
            title: 'Nearby',
            badge: s.discovery.scanning
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : s.nearby.discovering
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: scheme.primary.withAlpha(38), borderRadius: BorderRadius.circular(13)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.bluetooth_searching_rounded, size: 14, color: scheme.primary),
                          const SizedBox(width: 4),
                          Text('Nearby on', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)),
                        ]),
                      )
                    : null,
            trailing: _more(),
          ),
          SectionCard(
            child: Orbit(
              nodes: nodes,
              armed: armed,
              centreLabel: 'You',
              emptyText: 'Looking for devices…',
              centre: KeyedSubtree(
                key: _centreKey,
                child: armed ? _orb(84) : const OrbitCore(child: Icon(Icons.wifi_tethering_rounded, size: 30)),
              ),
              dragFeedback: armed ? Material(type: MaterialType.transparency, child: _orb(64)) : null,
              onCentreTap: armed ? () => Island.toast('Drag onto a device, or tap one', icon: Icons.send_rounded) : null,
              onTap: (n, r) => _tap(byKey[n.key]!, r),
              onLongPress: (n, r) => _menu(byKey[n.key]!, n, r),
              onDrop: (n, r) => _launch(byKey[n.key]!, r, dropped: true),
            ),
          ),
          if (extra.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final t in extra)
                  ActionChip(
                    avatar: Icon(t.icon, size: 18),
                    label: Text(t.name),
                    onPressed: () => _tap(t, null),
                  ),
              ]),
            ),
          SectionFooter(!anyOnline
              ? 'Devices need LocalSend or ShareBro open on the same Wi‑Fi or hotspot. For ShareBro phones without Wi‑Fi, use ⋯ › Find phones without Wi‑Fi.'
              : armed
                  ? 'Tap a device, or drag the orb onto one. Touch and hold a device for more options.'
                  : 'Add something above, then tap a device to send it.'),
        ]);
      },
    );
  }
}
