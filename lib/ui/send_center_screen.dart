import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../share/send_center.dart';
import 'aurora.dart';
import 'devices.dart';
import 'find_me_screen.dart';
import 'glass.dart';
import 'motion.dart';
import 'receive_screen.dart';
import 'sections.dart';
import 'share_screen.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';

/// Every send in one place: progress per friend, retry, cancel, and "Send
/// to everyone" for all paired friends' new photos.
class SendCenterScreen extends StatefulWidget {
  const SendCenterScreen({super.key, required this.controller, this.tripId});

  final ScanController controller;
  final int? tripId;

  @override
  State<SendCenterScreen> createState() => _SendCenterScreenState();
}

class _SendCenterScreenState extends State<SendCenterScreen> {
  SendCenter get s => widget.controller.sharing;
  bool _queueing = false;

  @override
  void initState() {
    super.initState();
    s.open();
  }

  @override
  void dispose() {
    s.close();
    super.dispose();
  }

  Future<void> _everyone() async {
    setState(() => _queueing = true);
    final n = await s.sendToEveryone(tripId: widget.tripId);
    if (!mounted) return;
    setState(() => _queueing = false);
    Haptics.success();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          n == 0
              ? 'Nothing new to send. Pair a friend\'s phone by sending to them once from their page.'
              : 'Queued new photos for $n ${n == 1 ? 'friend' : 'friends'} — each starts when their phone is nearby',
        ),
      ),
    );
  }

  Future<void> _askPin(SendJob job) async {
    final text = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('PIN for ${job.deviceAlias}'),
        content: TextField(
          controller: text,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'Shown in LocalSend on their phone'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: const Text('Send')),
        ],
      ),
    );
    if (pin != null && pin.isNotEmpty) s.retry(job, pin: pin);
  }

  void _open(SendJob j) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => TransferScreen(controller: widget.controller, job: j)));

  Widget _row(SendJob j) => _JobRow(
        key: ValueKey(j.id),
        job: j,
        onOpen: () => _open(j),
        onCancel: () => s.cancelJob(j),
        onRetry: j.status == JobStatus.needsPin ? () => _askPin(j) : () => s.retry(j),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ListenableBuilder(
          listenable: Listenable.merge([s, s.server, s.receiver]),
          builder: (context, _) {
            final jobs = s.jobs.reversed.toList();
            final now = [for (final j in jobs) if (!j.finished && !j.canRetry) j];
            final earlier = [for (final j in jobs) if (j.finished || j.canRetry) j];
            final links = s.server.shares.values.toList();
            final finds = s.server.finds.values.toList();
            final r = s.receiver;
            return GlassScrollView(
              title: 'Sending',
              actions: [
                ToolbarCapsule(children: [
                  IconButton(
                    tooltip: 'History',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => TransferHistoryScreen(controller: widget.controller)),
                    ),
                    icon: const Icon(Icons.history_rounded),
                  ),
                ]),
              ],
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
                  sliver: SliverList.list(children: [
                    SectionCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const IconTile(icon: Icons.groups_rounded, color: Color(0xFF5E5CE6)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              const Text('Send to everyone', style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
                              const SizedBox(height: 2),
                              Text(
                                'Every named friend whose phone you\'ve paired gets the photos they don\'t have yet. '
                                'Friends who aren\'t nearby wait in the queue and start automatically.',
                                style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
                              ),
                            ]),
                          ),
                        ]),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                          onPressed: _queueing ? null : _everyone,
                          icon: _queueing
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send_rounded),
                          label: const Text('Send new photos to everyone'),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    SectionCard(
                      child: SectionRow(
                        leading: const IconTile(icon: Icons.download_rounded, color: Color(0xFF30B0C7)),
                        title: 'Receive',
                        subtitle: r.busy
                            ? 'Receiving from ${r.session!.from}…'
                            : r.enabled
                                ? 'On — friends can send to "${s.identity.alias}"'
                                : 'Let friends send you photos and files',
                        trailing: Switch(value: r.enabled, onChanged: s.setReceiving),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => ReceiveScreen(controller: widget.controller)),
                        ),
                      ),
                    ),
                    if (links.isNotEmpty || finds.isNotEmpty) ...[
                      const SectionHeader(title: 'Shared links'),
                      SectionCard.rows(rows: [
                        for (final f in finds)
                          SectionRow(
                            leading: const IconTile(icon: Icons.face_retouching_natural_rounded, color: Color(0xFFFF9F0A)),
                            title: 'Find my photos · ${f.title}',
                            subtitle: f.found.isEmpty
                                ? 'Nobody found yet'
                                : '${f.found.length} found: ${f.found.join(', ')}',
                            trailing: IconButton(
                              tooltip: 'Stop the link',
                              icon: const Icon(Icons.stop_circle_rounded),
                              onPressed: () => s.server.closeFind(f.id),
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => FindMeScreen(controller: widget.controller, existing: f),
                              ),
                            ),
                          ),
                        for (final l in links)
                          SectionRow(
                            leading: const IconTile(icon: Icons.qr_code_2_rounded, color: Color(0xFF5E5CE6)),
                            title: l.title,
                            subtitle: '${l.files.length} files · ${l.visitors.length} opened · ${l.downloads} downloads',
                            trailing: IconButton(
                              tooltip: 'Stop sharing',
                              icon: const Icon(Icons.stop_circle_rounded),
                              onPressed: () => s.server.closeShare(l.id),
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => WebShareScreen(controller: widget.controller, title: l.title, existing: l),
                              ),
                            ),
                          ),
                      ]),
                    ],
                    if (jobs.isEmpty) const _NothingSending(),
                    if (now.isNotEmpty) ...[
                      const SectionHeader(title: 'Now'),
                      SectionCard.rows(rows: [for (final j in now) _row(j)]).animate().fadeIn().moveY(begin: 10),
                    ],
                    if (earlier.isNotEmpty) ...[
                      SectionHeader(
                        title: 'Earlier',
                        trailing: s.jobs.any((j) => j.finished)
                            ? TextButton(onPressed: s.clearFinished, child: const Text('Clear'))
                            : null,
                      ),
                      SectionCard.rows(rows: [for (final j in earlier) _row(j)]).animate().fadeIn().moveY(begin: 10),
                    ],
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _eta(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds % 60}s left' : '${d.inSeconds}s left';

/// One send: the device inside a progress ring while it runs, a tick or a
/// cross once it's over.
class _JobRow extends StatelessWidget {
  const _JobRow({super.key, required this.job, required this.onCancel, required this.onRetry, required this.onOpen});

  final SendJob job;
  final VoidCallback onCancel, onRetry, onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final speed = job.speed, left = job.remaining;
    final label = switch (job.status) {
      JobStatus.preparing => 'Getting ${job.prepared} of ${job.count} ready…',
      JobStatus.waiting => 'Waiting for the phone to be nearby',
      JobStatus.asking => job.message ?? 'Waiting for them to accept…',
      JobStatus.sending => [
          'Sending ${(job.progress * 100).round()}%',
          if (speed != null) '${formatBytes(speed.round())}/s',
          if (left != null) _eta(left),
        ].join(' · '),
      JobStatus.done => 'Sent ${job.count} ${job.noun}',
      JobStatus.declined => job.message ?? 'Declined · tap Retry to try again',
      JobStatus.needsPin => '${job.deviceAlias} needs a PIN',
      JobStatus.failed => job.message ?? 'Didn\'t finish',
      JobStatus.cancelled => 'Cancelled',
    };
    final bad = job.canRetry;
    final live = !job.finished && !bad;
    final indeterminate = job.status == JobStatus.asking || job.status == JobStatus.waiting || job.status == JobStatus.preparing;
    final Widget leading;
    if (live) {
      leading = SizedBox.square(
        dimension: 40,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox.square(
            dimension: 40,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: job.progress),
              duration: 350.ms,
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => CircularProgressIndicator(
                value: indeterminate ? null : v,
                strokeWidth: 3.5,
                strokeCap: StrokeCap.round,
                backgroundColor: capsuleFill(context),
              ),
            ),
          ),
          CircleAvatar(
            radius: 14,
            backgroundColor: deviceColor(job.fingerprint),
            child: Icon(job.nearby ? Icons.bluetooth_rounded : Icons.smartphone_rounded, size: 15, color: Colors.white),
          ),
        ]),
      );
    } else {
      leading = IconTile(
        icon: switch (job.status) {
          JobStatus.done => Icons.check_rounded,
          JobStatus.cancelled => Icons.remove_rounded,
          JobStatus.needsPin => Icons.pin_rounded,
          _ => Icons.close_rounded,
        },
        color: job.status == JobStatus.done
            ? scheme.primary
            : job.status == JobStatus.cancelled
                ? const Color(0xFF8E8E93)
                : scheme.error,
        iconColor: job.status == JobStatus.done ? scheme.onPrimary : Colors.white,
      ).animate(key: ValueKey(job.status)).scaleXY(begin: 0.5, duration: 350.ms, curve: Curves.easeOutBack);
    }
    return InkWell(
      onTap: onOpen,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('${job.personName} → ${job.deviceAlias}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                AnimatedSwitcher(
                  duration: 200.ms,
                  child: Text(
                    label,
                    key: ValueKey(job.status),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: job.status == JobStatus.sending || bad ? FontWeight.w600 : FontWeight.w400,
                      color: job.status == JobStatus.sending
                          ? scheme.primary
                          : bad
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ]),
            ),
            if (live)
              IconButton(tooltip: 'Cancel', onPressed: onCancel, icon: const Icon(Icons.close_rounded))
            else if (bad)
              TextButton(onPressed: onRetry, child: Text(job.status == JobStatus.needsPin ? 'PIN' : 'Retry'))
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant.withAlpha(140)),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Nothing in the queue: a paper plane flying between two phones.
class _NothingSending extends StatefulWidget {
  const _NothingSending();

  @override
  State<_NothingSending> createState() => _NothingSendingState();
}

class _NothingSendingState extends State<_NothingSending> with SingleTickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _fly
        ..stop()
        ..value = 0.5;
    } else if (!_fly.isAnimating) {
      _fly.repeat();
    }
  }

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(children: [
        SizedBox(
          height: 150,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            final a = Offset(w * 0.25, 110), b = Offset(w * 0.75, 110), c = Offset(w / 2, 0);
            Offset at(double t) {
              final u = 1 - t;
              return a * (u * u) + c * (2 * u * t) + b * (t * t);
            }

            return AnimatedBuilder(
              animation: _fly,
              builder: (context, _) {
                final t = Curves.easeInOutSine.transform(_fly.value);
                final p = at(t), ahead = at(math.min(1, t + 0.01));
                final fade = (math.min(_fly.value, 1 - _fly.value) * 6).clamp(0.0, 1.0);
                return Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _DashedArc(a, b, c, scheme.onSurfaceVariant.withAlpha(90), _fly.value)),
                  ),
                  for (final (pos, icon, color, fg) in [
                    (a, Icons.smartphone_rounded, scheme.primary, scheme.onPrimary),
                    (b, Icons.computer_rounded, const Color(0xFF6E5BFF), Colors.white),
                  ])
                    Positioned(
                      left: pos.dx - 32,
                      top: pos.dy - 32,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                        child: Icon(icon, color: fg, size: 28),
                      ),
                    ),
                  Positioned(
                    left: p.dx - 13,
                    top: p.dy - 13,
                    child: Opacity(
                      opacity: fade,
                      child: Transform.rotate(
                        angle: (ahead - p).direction,
                        child: Icon(Icons.send_rounded, size: 26, color: scheme.primary),
                      ),
                    ),
                  ),
                ]);
              },
            );
          }),
        ),
        const SizedBox(height: 8),
        const Text('Nothing sending right now', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SectionFooter('Pick something in the Share tab, or open a person and tap Send.', align: TextAlign.center),
      ]),
    );
  }
}

class _DashedArc extends CustomPainter {
  _DashedArc(this.a, this.b, this.c, this.color, this.phase);

  final Offset a, b, c;
  final Color color;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(c.dx, c.dy, b.dx, b.dy);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = color;
    const dash = 3.0, gap = 9.0;
    for (final m in path.computeMetrics()) {
      for (var d = (phase * 4 * (dash + gap)) % (dash + gap) - (dash + gap); d < m.length; d += dash + gap) {
        final s = d.clamp(0.0, m.length), e = (d + dash).clamp(0.0, m.length);
        if (e > s) canvas.drawPath(m.extractPath(s, e), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedArc old) => old.phase != phase || old.color != color;
}
