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
import 'file_icons.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';
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
    this.height = 250,
  });

  final TransferPhase phase;
  final String fromName, toName;
  final IconData fromIcon, toIcon;
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
      TransferPhase.done => Colors.green,
      TransferPhase.waiting => scheme.outline,
      _ => scheme.primary,
    };
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth, h = widget.height;
          final a = Offset(_avatar / 2 + 8, h - _avatar / 2 - 34);
          final b = Offset(w - _avatar / 2 - 8, h - _avatar / 2 - 34);
          final c = Offset(w / 2, 18);
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
                  // A "tap Accept" bubble over their phone while we wait.
                  if (phase == TransferPhase.asking)
                    Positioned(
                      left: b.dx - 26,
                      top: b.dy - _avatar / 2 - 58,
                      child: Transform.translate(
                        offset: Offset(0, math.sin(v * math.pi * 2) * 4),
                        child: Glass(
                          radius: 18,
                          padding: const EdgeInsets.all(10),
                          child: Icon(Icons.touch_app_rounded, color: scheme.tertiary),
                        ),
                      ),
                    ),
                  _DeviceAvatar(
                    center: a,
                    size: _avatar,
                    icon: widget.fromIcon,
                    name: widget.fromName,
                    active: phase != TransferPhase.waiting,
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
                    active: phase != TransferPhase.waiting,
                    tint: switch (phase) {
                      TransferPhase.done => Colors.green,
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
  final Color? tint;

  /// 0..1 loop value: a soft ring breathes out while sending.
  final double? pulse;

  /// 0..1 loop value: radar rings while looking for the device.
  final double? radar;
  final int bump;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = tint != null
        ? [tint!, tint!]
        : active
        ? [scheme.primary, scheme.tertiary]
        : [scheme.surfaceContainerHighest, scheme.surfaceContainerHigh];
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
                          border: Border.all(color: colors.first.withValues(alpha: (1 - t) * 0.5), width: 2),
                        ),
                      );
                    }(),
                AnimatedContainer(
                      duration: 300.ms,
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                        boxShadow: active
                            ? [
                                BoxShadow(
                                  color: colors.first.withValues(alpha: 0.35),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ]
                            : null,
                      ),
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
                          color: active ? Colors.white : scheme.outline,
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
    const colors = [Color(0xFFFF8A5C), Color(0xFFE8457A), Color(0xFF6E5BFF), Color(0xFF2BB5A6), Color(0xFFFFD84D)];
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
      ..strokeWidth = 3
      ..color = color.withValues(alpha: solid ? 0.8 : 0.55);
    if (solid) {
      canvas.drawPath(path, paint);
      return;
    }
    const dash = 10.0, gap = 9.0;
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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: 400.ms,
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => Column(
            children: [
              Text(
                '${(v * 100).round()}%',
                style: text.displayMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 10,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.15),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: 200.ms,
          child: Text(
            caption,
            key: ValueKey(caption),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall,
          ),
        ),
        if (stats.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              for (final (label, value) in stats)
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        value,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(label, style: text.labelSmall),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
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
                        backgroundColor: Colors.green,
                        child: const Icon(Icons.check_rounded, size: 11, color: Colors.white),
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
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
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
            title: const Text('Sending'),
            actions: [
              IconButton(
                tooltip: 'All sends',
                onPressed: () => Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => SendCenterScreen(controller: controller)),
                ),
                icon: const Icon(Icons.view_list_rounded),
              ),
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
              final color = switch (phase) {
                TransferPhase.done => Colors.green,
                TransferPhase.failed => scheme.error,
                _ => scheme.primary,
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
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Glass(
                    radius: 32,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                    child: Column(
                      children: [
                        TransferStage(
                          phase: phase,
                          fromName: 'You',
                          toName: job.deviceAlias,
                          toIcon: job.nearby ? Icons.bluetooth_connected_rounded : Icons.smartphone_rounded,
                          filesDone: job.filesDone,
                          token: (i) => itemTile(job.items[i % job.items.length]),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: TransferStats(
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
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.96, curve: Curves.easeOutCubic),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: FileMosaic(
                        count: job.items.length,
                        tile: (i) => itemTile(job.items[i]),
                        isDone: (i) => job.status == JobStatus.done || i < job.filesDone,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (job.status == JobStatus.done)
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Done'),
                    ).animate().fadeIn().moveY(begin: 12)
                  else if (job.canRetry)
                    FilledButton.icon(
                      onPressed: () => _retry(context),
                      icon: Icon(job.status == JobStatus.needsPin ? Icons.pin_rounded : Icons.refresh_rounded),
                      label: Text(job.status == JobStatus.needsPin ? 'Enter PIN' : 'Try again'),
                    )
                  else if (!job.finished)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              Haptics.remove();
                              s.cancelJob(job);
                            },
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.tonal(onPressed: () => Navigator.pop(context), child: const Text('Hide')),
                        ),
                      ],
                    ),
                  if (!job.finished && !job.canRetry)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'It keeps going in the background if you leave.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
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
          appBar: AppBar(title: const Text('Receiving')),
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
              final color = switch (phase) {
                TransferPhase.done => Colors.green,
                TransferPhase.failed => scheme.error,
                _ => scheme.primary,
              };
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  Glass(
                    radius: 32,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                    child: Column(
                      children: [
                        TransferStage(
                          phase: phase,
                          fromName: session.from,
                          toName: 'You',
                          filesDone: session.done.length,
                          token: (i) => files.isEmpty ? const SizedBox() : _incomingTile(files[i % files.length]),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: TransferStats(
                            title: 'From ${session.from}',
                            caption: session.finished
                                ? (session.cancelled ? 'Stopped' : 'Everything arrived and was saved')
                                : '${session.done.length} of ${session.tokens.length} arrived',
                            progress: progress,
                            color: color,
                            stats: [
                              ('received', formatBytes(session.bytes)),
                              ('speed', speed == null ? '–' : '${formatBytes(speed.round())}/s'),
                              ('left', left == null ? '–' : _eta(left)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 300.ms).scaleXY(begin: 0.96, curve: Curves.easeOutCubic),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: FileMosaic(
                        count: files.length,
                        tile: (i) => _incomingTile(files[i]),
                        isDone: (i) => session.done.contains(files[i].id),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (session.finished)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(builder: (_) => TransferHistoryScreen(controller: controller)),
                            ),
                            icon: const Icon(Icons.history_rounded),
                            label: const Text('History'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.check_rounded),
                            label: const Text('Done'),
                          ),
                        ),
                      ],
                    ).animate().fadeIn().moveY(begin: 12)
                  else
                    FilledButton.tonal(onPressed: () => Navigator.pop(context), child: const Text('Hide')),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
