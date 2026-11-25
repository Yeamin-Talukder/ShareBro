import 'package:flutter/material.dart';

import '../data/dates.dart';
import '../platform/device.dart';
import '../share/native_files.dart';
import '../update/release.dart';
import '../update/updater.dart';
import 'island.dart';
import 'theme.dart';

/// Settings › Software update on a computer, like a Mac's: the app and its
/// version, where the update stands, one clear button for the next step,
/// and what's new in the version on offer.
class SoftwareUpdatePanel extends StatefulWidget {
  const SoftwareUpdatePanel({super.key});

  @override
  State<SoftwareUpdatePanel> createState() => _SoftwareUpdatePanelState();
}

class _SoftwareUpdatePanelState extends State<SoftwareUpdatePanel> {
  Updater get u => Updater.instance;

  @override
  void initState() {
    super.initState();
    // Opening the panel looks again, unless it looked a moment ago or
    // something is already under way.
    // After the first frame: the check tells listeners (the sidebar too)
    // right away, which mustn't happen while this panel is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final last = u.checkedAt;
      final fresh = last != null && DateTime.now().difference(last) < const Duration(minutes: 10);
      if (!u.busy && !u.hasUpdate && !fresh) u.check(manual: true);
    });
  }

  Future<void> _install() async {
    final result = await u.install();
    if (!mounted || result == InstallResult.started) return;
    Island.toast("Couldn't start the installer. Try downloading again.", icon: Icons.error_outline_rounded);
  }

  /// "today at 14:05", "yesterday at 09:12", "3 Nov at 18:40".
  static String _when(DateTime t) {
    final now = DateTime.now();
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days == 0) return 'today at $time';
    if (days == 1) return 'yesterday at $time';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} at $time';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final r = u.release, a = u.apk;
        final offered = r != null && a != null && u.hasUpdate;
        final failedDownload = u.stage == UpdateStage.failed && r != null && a != null && r.version > u.current;

        final String status;
        Color? statusColor;
        switch (u.stage) {
          case UpdateStage.checking:
            status = 'Checking for updates…';
          case UpdateStage.available:
            status = 'Version ${r!.version} is available · ${formatBytes(a!.size)}';
            statusColor = scheme.primary;
          case UpdateStage.downloading:
            status = 'Downloading version ${r!.version}…';
          case UpdateStage.verifying:
            status = 'Checking the download…';
          case UpdateStage.ready:
            status = 'Version ${r!.version} is ready. ShareBro will close, update and open again.';
            statusColor = scheme.primary;
          case UpdateStage.failed:
            status = u.error ?? 'Something went wrong. Try again.';
            statusColor = scheme.error;
          case UpdateStage.upToDate || UpdateStage.idle:
            final checked = u.checkedAt;
            status = checked == null
                ? 'Not checked yet'
                : r != null && !(r.version > u.current)
                    ? 'ShareBro is up to date · checked ${_when(checked)}'
                    : 'Last checked ${_when(checked)}';
        }

        final Widget action = switch (u.stage) {
          UpdateStage.available => FilledButton(onPressed: u.download, child: const Text('Update now')),
          UpdateStage.downloading => OutlinedButton(onPressed: u.cancel, child: const Text('Cancel')),
          UpdateStage.verifying => const SizedBox(
              width: 34, height: 34, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2.5))),
          UpdateStage.ready => FilledButton(
              onPressed: _install, child: Text(Device.desktop ? 'Restart and update' : 'Install update')),
          UpdateStage.checking => const OutlinedButton(
              onPressed: null,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Checking…'),
              ])),
          _ when failedDownload => FilledButton(onPressed: u.retry, child: const Text('Try again')),
          _ => OutlinedButton(onPressed: () => u.check(manual: true), child: const Text('Check for updates')),
        };

        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Mac.card(context),
            borderRadius: BorderRadius.circular(Mac.cardRadius),
            border: Border.all(color: Mac.hairline(context), width: 0.5),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/icon/app_icon_store_512.png',
                      width: 56, height: 56, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('ShareBro ${u.currentText}', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: Text(
                        status,
                        key: ValueKey(status),
                        style: text.bodyMedium?.copyWith(color: statusColor ?? scheme.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                action,
              ]),
            ),
            if (u.stage == UpdateStage.downloading || u.stage == UpdateStage.verifying)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: u.stage == UpdateStage.verifying ? null : u.progress,
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (u.stage == UpdateStage.downloading && a != null)
                    Text(
                      '${formatBytes(u.received)} of ${formatBytes(a.size)}'
                      '${u.remaining == null ? '' : ' · about ${_left(u.remaining!)} left'}',
                      style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                ]),
              ),
            if (r != null && (offered || failedDownload) && (r.notes.isNotEmpty || r.summary.isNotEmpty)) ...[
              Divider(height: 0.5, thickness: 0.5, color: Mac.hairline(context)),
              _WhatsNew(release: r, onSkip: u.stage == UpdateStage.available ? u.skip : null),
            ],
          ]),
        );
      },
    );
  }

  static String _left(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';
}

/// What's new in the version on offer, a link to the full notes, and
/// "Skip this version".
class _WhatsNew extends StatelessWidget {
  const _WhatsNew({required this.release, this.onSkip});

  final Release release;
  final VoidCallback? onSkip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = release;
    final when = r.published == null ? null : releasedAgo(r.published!, DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text("What's new in ${r.version}", style: text.titleSmall),
          if (when != null) ...[
            const SizedBox(width: 8),
            Text('Released $when', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ]),
        if (r.summary.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(r.summary, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 6),
        for (final n in r.notes.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 10),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    if (n.title.isNotEmpty)
                      TextSpan(text: n.text.isEmpty ? n.title : '${n.title}. ', style: const TextStyle(fontWeight: FontWeight.w600)),
                    TextSpan(text: n.text),
                  ]),
                  style: text.bodyMedium,
                ),
              ),
            ]),
          ),
        const SizedBox(height: 6),
        Row(children: [
          if (r.page != null)
            TextButton.icon(
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: () => NativeFiles.open(r.page!),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('Full release notes'),
            ),
          const Spacer(),
          if (onSkip != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.onSurfaceVariant),
              onPressed: onSkip,
              child: const Text('Skip this version'),
            ),
        ]),
      ]),
    );
  }
}
