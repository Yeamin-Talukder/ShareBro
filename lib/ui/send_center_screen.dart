import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../share/send_center.dart';
import 'aurora.dart';
import 'motion.dart';
import 'receive_screen.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';
import 'widgets.dart';

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

  @override
  Widget build(BuildContext context) {
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Sending'),
          actions: [
            ListenableBuilder(
              listenable: s,
              builder: (context, _) => s.jobs.any((j) => j.finished)
                  ? TextButton(onPressed: s.clearFinished, child: const Text('Clear done'))
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([s, s.server, s.receiver]),
          builder: (context, _) {
            final jobs = s.jobs.reversed.toList();
            final links = s.server.shares.values.toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Send to everyone',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Every named friend whose phone you\'ve paired gets the photos they don\'t have yet. '
                          'Friends who aren\'t nearby wait in the queue and start automatically.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _queueing ? null : _everyone,
                          icon: _queueing
                              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.groups_rounded),
                          label: const Text('Send new photos to everyone'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: s.receiver.enabled
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.download_rounded,
                        color: s.receiver.enabled ? Theme.of(context).colorScheme.onPrimary : null,
                      ),
                    ),
                    title: const Text('Receive'),
                    subtitle: Text(
                      s.receiver.busy
                          ? 'Receiving from ${s.receiver.session!.from}…'
                          : s.receiver.enabled
                          ? 'On — friends can send to "${s.identity.alias}"'
                          : 'Let friends send you photos and files',
                    ),
                    trailing: Switch(value: s.receiver.enabled, onChanged: s.setReceiving),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ReceiveScreen(controller: widget.controller)),
                    ),
                  ),
                ),
                if (links.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Shared links',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  for (final l in links)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.qr_code_2)),
                          title: Text(l.title),
                          subtitle: Text(
                            '${l.files.length} files · ${l.visitors.length} opened · '
                            '${l.downloads} downloads',
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  WebShareScreen(controller: widget.controller, title: l.title, existing: l),
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: 'Stop sharing',
                            icon: const Icon(Icons.stop_circle_outlined),
                            onPressed: () => s.server.closeShare(l.id),
                          ),
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                if (jobs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 40),
                    child: EmptyIllustration(
                      message:
                          'Nothing sending right now.\nPick something in the Share tab, or open a person and tap Send.',
                    ),
                  )
                else
                  for (final (i, j) in jobs.indexed)
                    _JobCard(
                      key: ValueKey(j.id),
                      job: j,
                      onOpen: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TransferScreen(controller: widget.controller, job: j),
                        ),
                      ),
                      onCancel: () => s.cancelJob(j),
                      onRetry: j.status == JobStatus.needsPin ? () => _askPin(j) : () => s.retry(j),
                    ).animate().fadeIn(delay: (30 * i.clamp(0, 8)).ms).moveY(begin: 10),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _eta(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes}m ${d.inSeconds % 60}s left' : '${d.inSeconds}s left';

class _JobCard extends StatelessWidget {
  const _JobCard({super.key, required this.job, required this.onCancel, required this.onRetry, required this.onOpen});

  final SendJob job;
  final VoidCallback onCancel, onRetry, onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final speed = job.speed, left = job.remaining;
    final (label, color, icon) = switch (job.status) {
      JobStatus.preparing => (
        'Preparing ${job.prepared} of ${job.count}…',
        scheme.primary,
        Icons.hourglass_top_rounded,
      ),
      JobStatus.waiting => ('Waiting for ${job.deviceAlias} to be nearby', scheme.outline, Icons.schedule_rounded),
      JobStatus.asking => (job.message ?? 'Waiting for them to accept…', scheme.tertiary, Icons.touch_app_rounded),
      JobStatus.sending => (
        [
          '${job.filesDone} of ${job.count}',
          '${formatBytes(job.sentBytes)} of ${formatBytes(job.totalBytes)}',
          if (speed != null) '${formatBytes(speed.round())}/s',
          if (left != null) _eta(left),
        ].join(' · '),
        scheme.primary,
        Icons.north_east_rounded,
      ),
      JobStatus.done => ('Sent ${job.count} ${job.noun}', Colors.green, Icons.check_rounded),
      JobStatus.declined => (job.message ?? 'Declined', scheme.error, Icons.block_rounded),
      JobStatus.needsPin => ('${job.deviceAlias} needs a PIN', scheme.error, Icons.pin_rounded),
      JobStatus.failed => (job.message ?? 'Didn\'t finish', scheme.error, Icons.error_outline_rounded),
      JobStatus.cancelled => ('Cancelled', scheme.outline, Icons.cancel_outlined),
    };
    final indeterminate = job.status == JobStatus.asking || job.status == JobStatus.waiting;
    final done = job.status == JobStatus.done;
    return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    // Progress ring with the status icon (or percentage) inside.
                    SizedBox.square(
                      dimension: 58,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: job.progress),
                        duration: 350.ms,
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox.square(
                              dimension: 58,
                              child: CircularProgressIndicator(
                                value: indeterminate ? null : v,
                                strokeWidth: 5,
                                strokeCap: StrokeCap.round,
                                color: color,
                                backgroundColor: color.withValues(alpha: 0.15),
                              ),
                            ),
                            AnimatedSwitcher(
                              duration: 300.ms,
                              transitionBuilder: (c, a) => ScaleTransition(
                                scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                                child: c,
                              ),
                              child: job.status == JobStatus.sending
                                  ? Text(
                                      '${(v * 100).round()}%',
                                      key: const ValueKey('pct'),
                                      style: text.labelLarge?.copyWith(fontWeight: FontWeight.w800, color: color),
                                    )
                                  : Icon(icon, key: ValueKey(job.status), color: color, size: done ? 30 : 24),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${job.personName} → ${job.deviceAlias}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          AnimatedSwitcher(
                            duration: 200.ms,
                            child: Text(
                              label,
                              key: ValueKey(job.status),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: done ? Colors.green : null),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (!job.finished && !job.canRetry)
                      IconButton(tooltip: 'Cancel', onPressed: onCancel, icon: const Icon(Icons.close_rounded))
                    else if (job.canRetry)
                      FilledButton.tonal(
                        onPressed: onRetry,
                        child: Text(job.status == JobStatus.needsPin ? 'PIN' : 'Retry'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        )
        // A little pop when it lands.
        .animate(target: done ? 1 : 0)
        .scaleXY(end: 1.02, duration: 160.ms, curve: Curves.easeOut)
        .then()
        .scaleXY(end: 1 / 1.02, duration: 220.ms, curve: Curves.easeOutBack);
  }
}
