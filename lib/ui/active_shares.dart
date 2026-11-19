import 'package:flutter/material.dart';

import '../scan/scan_controller.dart';
import '../share/send_center.dart' show JobStatus;
import 'find_me_screen.dart';
import 'island.dart' show pageNavigator;
import 'receive_screen.dart';
import 'scan_helper_ui.dart';
import 'sections.dart';
import 'send_center_screen.dart';
import 'theme.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';

/// One thing being shared right now: an open link (QR), a "Find my photos"
/// link, a send under way, a receive, or being visible to nearby devices.
class ActiveShare {
  const ActiveShare({
    required this.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.open,
    this.progress,
    this.stop,
    this.stopLabel = 'Stop',
    this.quiet = false,
  });

  final String key;
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback open;

  /// 0..1 while files are moving.
  final double? progress;

  /// Ends it (null when it can't be stopped from here).
  final VoidCallback? stop;
  final String stopLabel;

  /// A standing state (visible to nearby devices) rather than something
  /// being shared; not counted in the live badge.
  final bool quiet;
}

void _open(Widget screen) => pageNavigator?.push(MaterialPageRoute(builder: (_) => screen));

/// Everything being shared right now, links first.
List<ActiveShare> activeShares(ScanController c) {
  final s = c.sharing, server = s.server, r = s.receiver;
  final out = <ActiveShare>[];
  // Galleries a Find link opened belong to that link.
  final fromFinds = {for (final f in server.finds.values) ...f.galleries.values};
  for (final f in server.finds.values) {
    out.add(ActiveShare(
      key: 'find-${f.id}',
      icon: Icons.face_retouching_natural_rounded,
      color: const Color(0xFFFF9F0A),
      title: 'Find my photos · ${f.title}',
      subtitle: f.found.isEmpty ? 'Link open · nobody found yet' : 'Link open · ${f.found.length} found',
      open: () => _open(FindMeScreen(controller: c, existing: f)),
      stop: () => server.closeFind(f.id),
    ));
  }
  for (final l in server.shares.values) {
    if (fromFinds.contains(l.id)) continue;
    final opened = l.visitors.length;
    out.add(ActiveShare(
      key: 'link-${l.id}',
      icon: Icons.qr_code_2_rounded,
      color: const Color(0xFF5E5CE6),
      title: l.title,
      subtitle: 'Link open · ${opened == 0 ? 'not opened yet' : '$opened opened'} · '
          '${l.downloads} ${l.downloads == 1 ? 'download' : 'downloads'}${l.pin == null ? '' : ' · PIN'}',
      open: () => _open(WebShareScreen(controller: c, title: l.title, existing: l)),
      stop: () => server.closeShare(l.id),
    ));
  }
  for (final j in s.jobs.reversed) {
    if (j.finished || j.canRetry) continue;
    out.add(ActiveShare(
      key: 'job-${j.id}',
      icon: Icons.north_east_rounded,
      color: Brand.accentLight,
      title: 'Sending ${j.count} ${j.noun} to ${j.deviceAlias}',
      subtitle: switch (j.status) {
        JobStatus.waiting => 'Waiting for the device',
        JobStatus.asking => 'Waiting for them to accept',
        JobStatus.preparing => 'Getting the files ready',
        JobStatus.sending => '${j.filesDone} of ${j.count} sent',
        _ => '',
      },
      progress: j.active ? j.progress : null,
      open: () => _open(TransferScreen(controller: c, job: j)),
      stop: () => s.cancelJob(j),
    ));
  }
  for (final h in c.scanHelper?.active ?? const []) {
    out.add(ActiveShare(
      key: 'scan-${h.token}',
      icon: Icons.memory_rounded,
      color: const Color(0xFF5E5CE6),
      title: 'Scanning for ${h.alias}',
      subtitle: [
        '${h.photos} ${h.photos == 1 ? 'photo' : 'photos'} here',
        '${formatRate(h.rate)} photos/s',
        if (h.remaining case final left?) '$left left',
      ].join(' · '),
      progress: h.phoneDone != null && (h.phoneTotal ?? 0) > 0 ? h.phoneDone! / h.phoneTotal! : null,
      open: () => _open(ScanHelperDashboard(controller: c)),
      stop: () => c.scanHelper?.stop(h),
    ));
  }
  final session = r.session;
  if (r.busy && session != null) {
    final total = session.tokens.length, got = session.done.length;
    out.add(ActiveShare(
      key: 'receive',
      icon: Icons.south_west_rounded,
      color: const Color(0xFF34C759),
      title: 'Receiving from ${session.from}',
      subtitle: '$got of $total ${total == 1 ? 'file' : 'files'}',
      progress: session.totalBytes == 0 ? null : (session.bytes / session.totalBytes).clamp(0.0, 1.0),
      open: () => _open(ReceiveScreen(controller: c)),
    ));
  } else if (r.enabled) {
    out.add(ActiveShare(
      key: 'visible',
      icon: Icons.wifi_tethering_rounded,
      color: const Color(0xFF30B0C7),
      title: 'Visible to nearby devices',
      subtitle: 'Others can send to "${s.identity.alias}"',
      open: () => _open(ReceiveScreen(controller: c)),
      stop: () => s.setReceiving(false),
      stopLabel: 'Turn off',
      quiet: true,
    ));
  }
  return out;
}

/// How many things are being shared right now (not counting just being
/// visible), for the sidebar's live badge.
int activeShareCount(ScanController c) => activeShares(c).where((a) => !a.quiet).length;

/// Rebuilds whenever anything about sharing changes.
class ActiveSharesBuilder extends StatelessWidget {
  const ActiveSharesBuilder({super.key, required this.controller, required this.builder});

  final ScanController controller;
  final Widget Function(BuildContext context, List<ActiveShare> shares) builder;

  @override
  Widget build(BuildContext context) {
    final s = controller.sharing;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.server, s.receiver, ?controller.scanHelper]),
      builder: (context, _) => builder(context, activeShares(controller)),
    );
  }
}

/// The sidebar's "Sharing now" card: a live dot, what's being shared, and
/// a Stop for each. In the icon rail, a dotted icon that opens Sending.
class SharingNowCard extends StatelessWidget {
  const SharingNowCard({super.key, required this.controller, required this.wide});

  final ScanController controller;
  final bool wide;

  static const _max = 3;

  @override
  Widget build(BuildContext context) {
    return ActiveSharesBuilder(
      controller: controller,
      builder: (context, all) {
        final live = all.where((a) => !a.quiet).toList();
        if (live.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        if (!wide) {
          return Tooltip(
            message: 'Sharing now: ${live.length}',
            child: InkResponse(
              onTap: () => _open(SendCenterScreen(controller: controller)),
              radius: 22,
              child: SizedBox(
                height: 44,
                child: Center(
                  child: Stack(clipBehavior: Clip.none, children: [
                    Icon(Icons.podcasts_rounded, size: 20, color: scheme.primary),
                    const Positioned(right: -3, top: -2, child: _Pulse()),
                  ]),
                ),
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Container(
            decoration: BoxDecoration(
              color: Mac.card(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Mac.hairline(context), width: 0.5),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InkWell(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                mouseCursor: SystemMouseCursors.click,
                onTap: () => _open(SendCenterScreen(controller: controller)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(11, 9, 10, 4),
                  child: Row(children: [
                    const _Pulse(),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Sharing now', style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
                    ),
                    Text('${live.length}',
                        style: TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600, color: Mac.green)),
                  ]),
                ),
              ),
              for (final a in live.take(_max)) _SidebarRow(share: a),
              if (live.length > _max)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 28), textStyle: const TextStyle(fontSize: TextSize.small)),
                  onPressed: () => _open(SendCenterScreen(controller: controller)),
                  child: Text('${live.length - _max} more'),
                ),
              const SizedBox(height: 4),
            ]),
          ),
        );
      },
    );
  }
}

class _SidebarRow extends StatefulWidget {
  const _SidebarRow({required this.share});

  final ActiveShare share;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.share;
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: a.open,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          padding: const EdgeInsets.fromLTRB(7, 5, 2, 5),
          decoration: BoxDecoration(
            color: _hover ? Mac.hover(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(Mac.rowRadius),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(color: a.color, borderRadius: BorderRadius.circular(5)),
                child: Icon(a.icon, size: 13, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w500)),
                  Text(a.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TextSize.tiny, color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (a.stop != null)
                IconButton(
                  tooltip: a.stopLabel,
                  iconSize: 16,
                  style: IconButton.styleFrom(minimumSize: const Size(26, 26), padding: const EdgeInsets.all(4)),
                  color: scheme.onSurfaceVariant,
                  onPressed: a.stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
            ]),
            if (a.progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 8, 1),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: a.progress, minHeight: 3),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The Share page's "Sharing now" list: each thing with Open and Stop.
class SharingNowSection extends StatelessWidget {
  const SharingNowSection({super.key, required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    return ActiveSharesBuilder(
      controller: controller,
      builder: (context, all) {
        if (all.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SectionHeader(title: 'Sharing now', top: 8, badge: _Pulse()),
          SectionCard.rows(rows: [
            for (final a in all)
              SectionRow(
                leading: IconTile(icon: a.icon, color: a.color),
                title: a.title,
                subtitle: a.subtitle,
                onTap: a.open,
                trailing: a.stop == null
                    ? null
                    : OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: a.quiet ? null : scheme.error,
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: a.stop,
                        child: Text(a.stopLabel),
                      ),
              ),
          ]),
          const SizedBox(height: 18),
        ]);
      },
    );
  }
}

/// A small green dot that pulses: something is live.
class _Pulse extends StatefulWidget {
  const _Pulse();

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        builder: (context, _) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Mac.green,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Mac.green.withValues(alpha: 0.5 * (1 - _a.value)), spreadRadius: 6 * _a.value)],
          ),
        ),
      );
}
