import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path/path.dart' as p;

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import '../share/protocol.dart';
import '../share/receive.dart';
import '../share/send_center.dart';
import 'aurora.dart';
import 'devices.dart';
import 'file_icons.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';
import 'sections.dart';
import 'send_center_screen.dart';
import 'share_screen.dart';
import 'widgets.dart';

/// Where a transfer is, as the stage draws it.
enum TransferPhase {
  /// The other device isn't around yet.
  waiting,

  /// Getting files ready, or waiting for them to tap Accept.
  asking,

  /// Bytes are flowing.
  flowing,
  done,
  failed,
}

/// Your phone on one side, theirs on the other, and the files flying along
/// an arc between them while the transfer runs. [tokens] builds the little
/// card for the n-th file in flight (a thumbnail or a file badge).
class TransferStage extends StatefulWidget {
  const TransferStage({
    super.key,
    required this.phase,
    required this.fromName,
    required this.toName,
    required this.token,
    required this.filesDone,
    this.fromIcon = Icons.smartphone_rounded,
    this.toIcon = Icons.smartphone_rounded,
    this.fromColor,
    this.toColor,
    this.status,
    this.height = 250,
  });

  final TransferPhase phase;
  final String fromName, toName;
  final IconData fromIcon, toIcon;

  /// Each phone's colour; null means the accent (that's you).
  final Color? fromColor, toColor;

  /// One line over the arc saying what's happening.
  final String? status;
  final Widget Function(int index) token;

  /// Bumps the receiving avatar each time a file lands.
  final int filesDone;
  final double height;

  @override
  State<TransferStage> createState() => _TransferStageState();
}

class _TransferStageState extends State<TransferStage> with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat();

  static const _inFlight = 4;
  static const _avatar = 78.0;

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    final phase = widget.phase;
    final lineColor = switch (phase) {
      TransferPhase.failed => scheme.error,
      TransferPhase.waiting => scheme.onSurfaceVariant.withAlpha(110),
      _ => scheme.primary,
    };
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth, h = widget.height;
          final a = Offset(_avatar / 2 + 8, h - _avatar / 2 - 34);
          final b = Offset(w - _avatar / 2 - 8, h - _avatar / 2 - 34);
          final c = Offset(w / 2, widget.status == null ? 18 : 44);
          Offset at(double t) {
            final u = 1 - t;
            return a * (u * u) + c * (2 * u * t) + b * (t * t);
          }

          return AnimatedBuilder(
            animation: _loop,
            builder: (context, _) {
              final v = still ? 0.3 : _loop.value;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ArcPainter(
                        a: a,
                        b: b,
                        c: c,
                        color: lineColor,
                        phase: v,
                        moving: phase == TransferPhase.flowing || phase == TransferPhase.asking,
                        solid: phase == TransferPhase.done,
                      ),
                    ),
                  ),
                  // Files in flight: they rise from your phone, swell at the top
                  // of the arc and shrink into theirs.
                  if (phase == TransferPhase.flowing)
                    for (var k = 0; k < _inFlight; k++)
                      () {
                        final t = (v + k / _inFlight) % 1.0;
                        final pos = at(t);
                        final s = math.sin(t * math.pi);
                        return Positioned(
                          left: pos.dx - 22,
                          top: pos.dy - 22,
                          child: Opacity(
                            opacity: (s * 1.4).clamp(0.0, 1.0),
                            child: Transform.rotate(
                              angle: (t - 0.5) * 0.6,
                              child: Transform.scale(
                                scale: 0.55 + 0.55 * s,
                                child: _Token(child: widget.token(widget.filesDone + k)),
                              ),
                            ),
                          ),
                        );
                      }(),
                  // An "Accept?" bubble over their phone while we wait.
                  if (phase == TransferPhase.asking)
                    Positioned(
                      left: b.dx - 80,
                      width: 160,
                      top: b.dy - _avatar / 2 - 48,
                      child: Center(
                        child: Transform.translate(
                          offset: Offset(0, math.sin(v * math.pi * 2) * 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(16)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.touch_app_rounded, size: 16, color: scheme.primary),
                              const SizedBox(width: 5),
                              const Text('Accept?',
                                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white)),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  if (widget.status != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 4,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(
                          switch (phase) {
                            TransferPhase.waiting => Icons.wifi_tethering_rounded,
                            TransferPhase.asking => Icons.touch_app_rounded,
                            TransferPhase.flowing => Icons.send_rounded,
                            TransferPhase.done => Icons.check_circle_rounded,
                            TransferPhase.failed => Icons.error_rounded,
                          },
                          size: 17,
                          color: phase == TransferPhase.failed ? scheme.error : scheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(widget.status!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: phase == TransferPhase.failed ? scheme.error : scheme.onSurfaceVariant,
                              )),
                        ),
                      ]),
                    ),
                  _DeviceAvatar(
                    center: a,
                    size: _avatar,
                    icon: widget.fromIcon,
                    name: widget.fromName,
                    color: widget.fromColor,
                    active: true,
                    pulse: phase == TransferPhase.flowing ? v : null,
                  ),
                  _DeviceAvatar(
                    center: b,
                    size: _avatar,
                    icon: switch (phase) {
                      TransferPhase.done => Icons.check_rounded,
                      TransferPhase.failed => Icons.close_rounded,
                      _ => widget.toIcon,
                    },
                    name: widget.toName,
                    color: widget.toColor,
                    active: phase != TransferPhase.waiting,
                    tint: switch (phase) {
                      TransferPhase.done => scheme.primary,
                      TransferPhase.failed => scheme.error,
                      _ => null,
                    },
                    radar: phase == TransferPhase.waiting ? v : null,
                    bump: widget.filesDone,
                  ),
                  if (phase == TransferPhase.done) _Burst(center: b),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Token extends StatelessWidget {
  const _Token({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 3))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(10), child: child),
    );
  }
}

class _DeviceAvatar extends StatelessWidget {
  const _DeviceAvatar({
    required this.center,
    required this.size,
    required this.icon,
    required this.name,
    required this.active,
    this.color,
    this.tint,
    this.pulse,
    this.radar,
    this.bump = 0,
  });

  final Offset center;
  final double size;
  final IconData icon;
  final String name;
  final bool active;

  /// The phone's own colour; null means the accent.
  final Color? color;
  final Color? tint;

  /// 0..1 loop value: a soft ring breathes out while sending.
  final double? pulse;

  /// 0..1 loop value: radar rings while looking for the device.
  final double? radar;
  final int bump;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = tint ??
        (active ? (color ?? scheme.primary) : (dark ? const Color(0xFF3A3A40) : const Color(0xFFD1D1D6)));
    // Rings in the phone's colour; radar rings in the accent.
    final ringColor = radar != null ? scheme.primary : fill;
    final onFill = tint == scheme.primary || (tint == null && active && color == null) ? scheme.onPrimary : Colors.white;
    final ring = pulse ?? radar;
    return Positioned(
      left: center.dx - 60,
      top: center.dy - size / 2,
      width: 120,
      child: Column(
        children: [
          SizedBox.square(
            dimension: size,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (ring != null)
                  for (final off in radar != null ? const [0.0, 0.5] : const [0.0])
                    () {
                      final t = (ring + off) % 1.0;
                      return Container(
                        width: size * (1 + t * 0.6),
                        height: size * (1 + t * 0.6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: ringColor.withValues(alpha: (1 - t) * 0.6), width: 2),
                        ),
                      );
                    }(),
                AnimatedContainer(
                      duration: 300.ms,
                      width: size,
                      height: size,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
                      child: AnimatedSwitcher(
                        duration: 300.ms,
                        transitionBuilder: (c, a) => ScaleTransition(
                          scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                          child: c,
                        ),
                        child: Icon(
                          icon,
                          key: ValueKey(icon),
                          size: size * 0.45,
                          color: active || tint != null ? onFill : scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                    // A little "gulp" each time a file arrives.
                    .animate(key: ValueKey(bump))
                    .scaleXY(begin: bump == 0 ? 1 : 1.12, end: 1, duration: 260.ms, curve: Curves.easeOutBack),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Dots bursting out of the receiving phone when everything has arrived.
class _Burst extends StatelessWidget {
  const _Burst({required this.center});

  final Offset center;

  @override
  Widget build(BuildContext context) {
    const colors = [Color(0xFFFF8A6B), Color(0xFFFFD60A), Color(0xFF5E5CE6), Color(0xFF30B0C7), Color(0xFF34C759)];
    // A zero-size anchor at the phone's centre; the dots fly out of it.
    return Positioned(
      left: center.dx,
      top: center.dy,
      width: 0,
      height: 0,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < 12; i++)
            () {
              final angle = i / 12 * math.pi * 2;
              final dist = 64.0 + (i % 3) * 14;
              return Positioned(
                left: -5,
                top: -5,
                child:
                    Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: colors[i % colors.length], shape: BoxShape.circle),
                        )
                        .animate()
                        .move(
                          end: Offset(math.cos(angle) * dist, math.sin(angle) * dist),
                          duration: 700.ms,
                          curve: Curves.easeOutCubic,
                        )
                        .scaleXY(begin: 0.4, end: 1.1, duration: 300.ms)
                        .then(delay: 250.ms)
                        .fadeOut(duration: 400.ms),
              );
            }(),
        ],
      ),
    );
  }
}

/// The dashed arc between the two phones; the dashes march towards the
/// receiver while files flow.
class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.a,
    required this.b,
    required this.c,
    required this.color,
    required this.phase,
    required this.moving,
    required this.solid,
  });

  final Offset a, b, c;
  final Color color;
  final double phase;
  final bool moving, solid;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(c.dx, c.dy, b.dx, b.dy);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.5
      ..color = color.withValues(alpha: solid ? 0.9 : 0.75);
    if (solid) {
      canvas.drawPath(path, paint);
      return;
    }
    const dash = 3.0, gap = 9.0;
    final shift = moving ? phase * (dash + gap) * 4 % (dash + gap) : 0.0;
    for (final PathMetric m in path.computeMetrics()) {
      for (var d = shift - (dash + gap); d < m.length; d += dash + gap) {
        final start = d.clamp(0.0, m.length);
        final end = (d + dash).clamp(0.0, m.length);
        if (end > start) canvas.drawPath(m.extractPath(start, end), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_ArcPainter old) => true;
}

/// The big numbers under the stage: percent, speed, time left.
class TransferStats extends StatelessWidget {
  const TransferStats({
    super.key,
    required this.title,
    required this.caption,
    required this.progress,
    required this.color,
    this.stats = const [],
  });

  final String title, caption;
  final double progress;
  final Color color;
  final List<(String label, String value)> stats;

  static IconData _icon(String label) => switch (label) {
        'speed' => Icons.speed_rounded,
        'left' => Icons.schedule_rounded,
        _ => Icons.photo_library_rounded,
      };

  static Color _tile(String label) => switch (label) {
        'speed' => const Color(0xFF30B0C7),
        'left' => const Color(0xFF5E5CE6),
        _ => const Color(0xFFFF9F0A),
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: title,
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: 400.ms,
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Column(
              children: [
                Text(
                  '${(v * 100).round()}%',
                  style: text.displayMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 8,
                      color: color,
                      backgroundColor: capsuleFill(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: 200.ms,
            child: Text(
              caption,
              key: ValueKey(caption),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 14),
            SectionCard(
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    for (final (i, (label, value)) in stats.indexed) ...[
                      if (i > 0) const VerticalDivider(width: 0.5, thickness: 0.5, indent: 14, endIndent: 14),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(color: _tile(label), borderRadius: BorderRadius.circular(8)),
                              child: Icon(_icon(label), size: 17, color: Colors.white),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                            Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          ]),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tiles for every file, lighting up with a check as each one arrives.
class FileMosaic extends StatelessWidget {
  const FileMosaic({super.key, required this.count, required this.tile, required this.isDone, this.limit = 48});

  final int count;
  final Widget Function(int i) tile;
  final bool Function(int i) isDone;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = math.min(count, limit);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < shown; i++)
          () {
            final done = isDone(i);
            return SizedBox.square(
              dimension: 46,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedOpacity(
                    opacity: done ? 1 : 0.4,
                    duration: 300.ms,
                    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: tile(i)),
                  ),
                  if (done)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: CircleAvatar(
                        radius: 8,
                        backgroundColor: scheme.primary,
                        child: Icon(Icons.check_rounded, size: 11, color: scheme.onPrimary),
                      ).animate().scaleXY(begin: 0, duration: 260.ms, curve: Curves.easeOutBack),
                    ),
                ],
              ),
            );
          }(),
        if (count > shown)
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(10)),
            child: Text('+${count - shown}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }
}

/// A small card for something being sent: its thumbnail, a file badge or
/// a message bubble.
Widget itemTile(SendItem item) {
  if (item.assetId != null) return AssetThumb(id: item.assetId!, size: 120);
  if (item.text != null) {
    return const ColoredBox(
      color: Color(0xFF2BB5A6),
      child: Icon(Icons.notes_rounded, color: Colors.white),
    );
  }
  final name = item.name ?? p.basename(item.path!);
  final look = fileLook(mimeFor(name), name);
  return ColoredBox(
    color: look.color,
    child: Icon(look.icon, color: Colors.white),
  );
}

Widget _incomingTile(IncomingFile f) {
  final look = fileLook(f.mime, f.fileName);
  return ColoredBox(
    color: look.color,
    child: Icon(look.icon, color: Colors.white),
  );
}

String _eta(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds % 60}s' : '${d.inSeconds}s';

/// A glass back button, as on the other inner pages.
Widget _backButton(BuildContext context) => Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Center(
        child: GlassIconButton(
          tooltip: 'Back',
          size: 44,
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.maybePop(context),
        ),
      ),
    );

/// Big title and a line under it.
Widget _heading(BuildContext context, String title, String subtitle) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.7)),
        Text(subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );

/// The files card: a header and every file lighting up as it lands.
Widget _filesCard(BuildContext context, String title, int bytes, Widget mosaic) => SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(formatBytes(bytes), style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
        const SizedBox(height: 10),
        mosaic,
      ]),
    );

/// Grey (or accent, for [main]) full-height capsule buttons.
Widget _button(BuildContext context, String label, IconData? icon, VoidCallback onPressed, {bool main = false}) {
  final style = FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(50),
    backgroundColor: main ? null : capsuleFill(context),
    foregroundColor: main ? null : Theme.of(context).colorScheme.onSurface,
  );
  return icon == null
      ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
      : FilledButton.icon(style: style, onPressed: onPressed, icon: Icon(icon), label: Text(label));
}

/// One send, live: the stage, the numbers and every file lighting up.
class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key, required this.controller, required this.job});

  final ScanController controller;
  final SendJob job;

  Future<void> _retry(BuildContext context) async {
    final s = controller.sharing;
    if (job.status != JobStatus.needsPin) {
      s.retry(job);
      return;
    }
    final text = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('PIN for ${job.deviceAlias}'),
        content: TextField(
          controller: text,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Shown on their Receive screen'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (pin != null && pin.isNotEmpty) s.retry(job, pin: pin);
  }

  @override
  Widget build(BuildContext context) {
    final s = controller.sharing;
    return IslandQuiet(
      child: Aurora(
        intensity: 0.8,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            leadingWidth: 64,
            leading: _backButton(context),
            actions: [
              ToolbarCapsule(children: [
                IconButton(
                  tooltip: 'All sends',
                  onPressed: () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => SendCenterScreen(controller: controller)),
                  ),
                  icon: const Icon(Icons.view_list_rounded),
                ),
              ]),
              const SizedBox(width: 12),
            ],
          ),
          body: ListenableBuilder(
            listenable: s,
            builder: (context, _) {
              final scheme = Theme.of(context).colorScheme;
              final phase = switch (job.status) {
                JobStatus.waiting => TransferPhase.waiting,
                JobStatus.preparing || JobStatus.asking => TransferPhase.asking,
                JobStatus.sending => TransferPhase.flowing,
                JobStatus.done => TransferPhase.done,
                _ => TransferPhase.failed,
              };
              final color = phase == TransferPhase.failed ? scheme.error : scheme.primary;
              final status = switch (job.status) {
                JobStatus.waiting => 'Looking for ${job.deviceAlias}…',
                JobStatus.preparing => 'Getting ready…',
                JobStatus.asking => 'Waiting for ${job.deviceAlias} to accept',
                JobStatus.sending => 'Sending',
                JobStatus.done => 'Sent',
                JobStatus.needsPin => '${job.deviceAlias} asks for a PIN',
                JobStatus.cancelled => 'Cancelled',
                JobStatus.declined => job.message ?? '${job.deviceAlias} declined',
                JobStatus.failed => job.message ?? 'Didn\'t finish',
              };
              final caption = switch (job.status) {
                JobStatus.waiting => 'Waiting for ${job.deviceAlias} to show up nearby…',
                JobStatus.preparing => 'Getting ${job.prepared} of ${job.count} ready…',
                JobStatus.asking => 'Waiting for ${job.deviceAlias} to tap Accept…',
                JobStatus.sending => '${job.filesDone} of ${job.count} arrived',
                JobStatus.done => 'Everything arrived',
                JobStatus.needsPin => '${job.deviceAlias} asks for a PIN',
                JobStatus.cancelled => 'Cancelled',
                _ => job.message ?? 'Didn\'t finish',
              };
              final speed = job.speed, left = job.remaining;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _heading(context, 'Sending', '${job.personName} to ${job.deviceAlias}'),
                  SectionCard(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                    child: TransferStage(
                      phase: phase,
                      status: status,
                      fromName: 'You',
                      toName: job.deviceAlias,
                      toIcon: job.nearby ? Icons.bluetooth_connected_rounded : Icons.smartphone_rounded,
                      toColor: deviceColor(job.fingerprint),
                      filesDone: job.filesDone,
                      height: 230,
                      token: (i) => itemTile(job.items[i % job.items.length]),
                    ),
                  ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.96, curve: Curves.easeOutCubic),
                  const SizedBox(height: 14),
                  TransferStats(
                    title: 'Sending ${job.personName} to ${job.deviceAlias}',
                    caption: caption,
                    progress: job.progress,
                    color: color,
                    stats: [
                      ('sent', formatBytes(job.sentBytes)),
                      ('speed', speed == null ? '–' : '${formatBytes(speed.round())}/s'),
                      ('left', left == null ? '–' : _eta(left)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _filesCard(
                    context,
                    'Files',
                    job.totalBytes,
                    FileMosaic(
                      count: job.items.length,
                      tile: (i) => itemTile(job.items[i]),
                      isDone: (i) => job.status == JobStatus.done || i < job.filesDone,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (job.status == JobStatus.done)
                    _button(context, 'Done', Icons.check_rounded, () => Navigator.pop(context), main: true)
                        .animate()
                        .fadeIn()
                        .moveY(begin: 12)
                  else if (job.canRetry)
                    Row(children: [
                      Expanded(child: _button(context, 'Close', null, () => Navigator.pop(context))),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _button(
                          context,
                          job.status == JobStatus.needsPin ? 'Enter PIN' : 'Try again',
                          job.status == JobStatus.needsPin ? Icons.pin_rounded : Icons.refresh_rounded,
                          () => _retry(context),
                          main: true,
                        ),
                      ),
                    ])
                  else if (!job.finished)
                    Row(
                      children: [
                        Expanded(
                          child: _button(context, 'Cancel', Icons.close_rounded, () {
                            Haptics.remove();
                            s.cancelJob(job);
                          }),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _button(context, 'Hide', null, () => Navigator.pop(context))),
                      ],
                    ),
                  if (!job.finished && !job.canRetry)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'It keeps going in the background if you leave.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What's arriving right now, live — the same stage, the other way round.
class ReceiveLiveScreen extends StatelessWidget {
  const ReceiveLiveScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final r = controller.sharing.receiver;
    return IslandQuiet(
      child: Aurora(
        intensity: 0.8,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(leadingWidth: 64, leading: _backButton(context)),
          body: ListenableBuilder(
            listenable: r,
            builder: (context, _) {
              final scheme = Theme.of(context).colorScheme;
              final session = r.session;
              if (session == null) {
                return const EmptyIllustration(message: 'Nothing arriving right now.');
              }
              final files = [for (final id in session.tokens.keys) ?session.files[id]];
              final total = session.totalBytes;
              final progress = session.finished ? 1.0 : (total == 0 ? 0.0 : session.bytes / total);
              final phase = session.finished
                  ? (session.cancelled ? TransferPhase.failed : TransferPhase.done)
                  : TransferPhase.flowing;
              final secs = DateTime.now().difference(session.started).inMilliseconds / 1000;
              final speed = secs < 1 || session.finished ? null : session.bytes / secs;
              final left = speed == null || speed <= 0
                  ? null
                  : Duration(seconds: ((total - session.bytes) / speed).ceil());
              final color = phase == TransferPhase.failed ? scheme.error : scheme.primary;
              final n = session.tokens.length;
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  _heading(context, 'Receiving', '$n ${n == 1 ? 'file' : 'files'} from ${session.from}'),
                  SectionCard(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                    child: TransferStage(
                      phase: phase,
                      status: switch (phase) {
                        TransferPhase.done => 'Saved',
                        TransferPhase.failed => 'Stopped',
                        _ => 'Receiving',
                      },
                      fromName: session.from,
                      fromIcon: Icons.devices_rounded,
                      fromColor: deviceColor(session.from),
                      toName: 'You',
                      filesDone: session.done.length,
                      height: 230,
                      token: (i) => files.isEmpty ? const SizedBox() : _incomingTile(files[i % files.length]),
                    ),
                  ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.96, curve: Curves.easeOutCubic),
                  const SizedBox(height: 14),
                  TransferStats(
                    title: 'From ${session.from}',
                    caption: session.finished
                        ? (session.cancelled ? 'Stopped' : 'Everything arrived and was saved')
                        : '${session.done.length} of $n arrived',
                    progress: progress,
                    color: color,
                    stats: [
                      ('received', formatBytes(session.bytes)),
                      ('speed', speed == null ? '–' : '${formatBytes(speed.round())}/s'),
                      ('left', left == null ? '–' : _eta(left)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _filesCard(
                    context,
                    session.finished ? 'Arrived' : 'Arriving',
                    total,
                    FileMosaic(
                      count: files.length,
                      tile: (i) => _incomingTile(files[i]),
                      isDone: (i) => session.done.contains(files[i].id),
                    ),
                  ),
                  const SectionFooter('Photos and videos go to the ShareBro album and are scanned for faces.'),
                  const SizedBox(height: 18),
                  if (session.finished)
                    Row(
                      children: [
                        Expanded(
                          child: _button(
                            context,
                            'History',
                            Icons.history_rounded,
                            () => Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(builder: (_) => TransferHistoryScreen(controller: controller)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: _button(context, 'Done', Icons.check_rounded, () => Navigator.pop(context), main: true)),
                      ],
                    ).animate().fadeIn().moveY(begin: 12)
                  else
                    _button(context, 'Hide', null, () => Navigator.pop(context)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
