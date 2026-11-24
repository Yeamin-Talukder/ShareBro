import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device.dart';
import '../scan/scan_controller.dart';
import '../share/protocol.dart';
import '../share/scan_helper.dart';
import 'island.dart';
import 'sections.dart';
import 'theme.dart';

/// Computer: when a phone asks to use this computer for scanning the first
/// time, asks here (with the code the phone shows) whether to allow it.
class ScanHelperWatcher extends StatefulWidget {
  const ScanHelperWatcher({super.key, required this.controller, required this.child});

  final ScanController controller;
  final Widget child;

  @override
  State<ScanHelperWatcher> createState() => _ScanHelperWatcherState();
}

class _ScanHelperWatcherState extends State<ScanHelperWatcher> {
  ScanHelpRequest? _shown;
  ScanHelperHub? get _hub => widget.controller.scanHelper;

  @override
  void initState() {
    super.initState();
    _hub?.addListener(_check);
  }

  @override
  void dispose() {
    _hub?.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final req = _hub?.pending;
    if (req == null || req == _shown || req.answered) return;
    _shown = req;
    _ask(req);
  }

  Future<void> _ask(ScanHelpRequest req) async {
    final ctx = islandNavigator.currentState?.context ?? context;
    final yes = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: const Icon(Icons.memory_rounded),
          title: Text('${req.alias} wants this computer to scan its photos'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'The phone sends small copies of its photos; this computer finds the faces and sends back only '
                'the results. Copies are never saved here. Once allowed, it won\'t ask again.',
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(req.code,
                    style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 8,
                        color: scheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              const SizedBox(height: 6),
              Text('Allow only if your phone shows the same code.',
                  style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Don\'t allow')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
          ],
        );
      },
    );
    req.answer(yes ?? false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Phone: Settings › Scan with my computer. Pair a computer (it asks there,
/// with a code), use it or not, or forget it.
class ScanHelperScreen extends StatefulWidget {
  const ScanHelperScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ScanHelperScreen> createState() => _ScanHelperScreenState();
}

class _ScanHelperScreenState extends State<ScanHelperScreen> {
  ScanController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    // Look for computers (and be seen) while this page is open.
    c.sharing.open();
    c.sharing.discovery.addListener(_refresh);
    c.addListener(_refresh);
  }

  @override
  void dispose() {
    c.sharing.discovery.removeListener(_refresh);
    c.removeListener(_refresh);
    c.sharing.close();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _pair(LsDevice pc) async {
    final code = (1000 + math.Random.secure().nextInt(9000)).toString();
    final waiting = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: Text('Allow on ${pc.alias}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Your computer asks whether to help. It should show this code:'),
            const SizedBox(height: 12),
            Text(code,
                style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 8,
                    color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ]),
        );
      },
    );
    String? problem;
    try {
      await c.pairHelper(pc, code);
    } on ScanHelpException catch (e) {
      problem = e.message;
    } catch (e) {
      problem = 'Couldn\'t pair: $e';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await waiting;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(problem ?? '${c.helperPcName ?? pc.alias} will help with your scans when it\'s nearby'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paired = c.helperPc != null;
    final nearby = c.helperNearby;
    final others = [for (final d in c.helperCandidates) if (d.fingerprint != c.helperPc) d];
    return Scaffold(
      appBar: AppBar(title: const Text('Scan with my computer')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        SectionCard(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const IconTile(icon: Icons.memory_rounded, color: Color(0xFF5E5CE6)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Scan much faster', style: TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'While a scan runs, your phone sends small copies of the photos to your computer, which finds the '
                  'faces on its graphics chip and sends back only the results. Your phone keeps scanning too, and '
                  'carries on alone if the computer goes away. Copies are never kept on the computer; face results '
                  'only if you allow it below.',
                  style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
        ),
        if (paired) ...[
          const SectionHeader(title: 'Your computer'),
          SectionCard.rows(rows: [
            SectionRow(
              leading: const IconTile(icon: Icons.laptop_rounded, color: Color(0xFF0A84FF)),
              title: c.helperPcName ?? 'Computer',
              subtitle: nearby != null ? 'On this Wi‑Fi · ready to help' : 'Not on this Wi‑Fi right now',
              trailing: Switch(value: c.helperOn, onChanged: c.setHelperOn),
              onTap: () => c.setHelperOn(!c.helperOn),
            ),
            SectionRow(
              leading: const IconTile(icon: Icons.link_off_rounded, color: Color(0xFFFF453A)),
              title: 'Forget this computer',
              destructive: true,
              onTap: c.forgetHelper,
            ),
          ]),
          const SectionHeader(title: 'Remember results on the computer'),
          SectionCard(
            padding: const EdgeInsets.all(12),
            child: CapsuleSwitch<int>(
              value: c.helperKeepDays,
              options: [
                for (final d in scanHelpKeepChoices) (d, d == 0 ? 'Off' : d == 1 ? '1 day' : '$d days', null),
              ],
              onChanged: c.setHelperKeepDays,
            ),
          ),
          SectionFooter(c.helperKeepDays == 0
              ? '${c.helperPcName ?? 'Your computer'} keeps nothing: every photo is scanned again each time.'
              : '${c.helperPcName ?? 'Your computer'} keeps the face results (not the photos) for '
                  '${c.helperKeepDays == 1 ? '1 day' : '${c.helperKeepDays} days'}, so the same photo is answered '
                  'instantly if it\'s scanned again. Turning this off deletes them there the next time it helps.'),
        ],
        SectionHeader(
          title: paired ? 'Other computers nearby' : 'Computers nearby',
          trailing: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        if (others.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Open ShareBro on your computer, on the same Wi‑Fi or hotspot as this phone.',
              style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
            ),
          )
        else
          SectionCard.rows(rows: [
            for (final d in others)
              SectionRow(
                leading: const IconTile(icon: Icons.computer_rounded, color: Color(0xFF8E8E93)),
                title: d.alias,
                subtitle: 'Tap to pair; your computer asks first',
                trailing: FilledButton.tonal(onPressed: () => _pair(d), child: const Text('Pair')),
                onTap: () => _pair(d),
              ),
          ]),
        const SectionFooter(
          'Only face results come back: where each face is, its fingerprint and a small face picture. '
          'Smiles and closed eyes are only read for photos this phone scans itself.',
        ),
      ]),
    );
  }
}

/// While scanning on a phone: "Your computer is helping · 240 photos", and
/// a switch to bring the computer in (or leave it out) mid-scan. Unpaired,
/// a way to set it up.
class ScanHelperBadge extends StatelessWidget {
  const ScanHelperBadge({super.key, required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (Device.desktop) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final h = c.helper;
    final name = c.helperPcName ?? 'your computer';
    final paired = c.helperPc != null;
    final String text;
    if (!paired) {
      text = 'Scan faster with your computer';
    } else if (h != null) {
      text = '${h.alias} is helping'
          '${c.helperPhotos == 0 ? '' : ' · ${c.helperPhotos} ${c.helperPhotos == 1 ? 'photo' : 'photos'} scanned there'}';
    } else if (c.joiningHelper) {
      text = 'Looking for $name…';
    } else if (c.helperOn) {
      text = "$name isn't on this Wi‑Fi yet · checking again soon";
    } else {
      text = 'Use $name for this scan';
    }
    void open() => Navigator.push(context, MaterialPageRoute(builder: (_) => ScanHelperScreen(controller: c)));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: const Color(0xFF5E5CE6).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: paired ? () => c.setHelperOn(!c.helperOn) : open,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
            child: Row(children: [
              const Icon(Icons.memory_rounded, size: 18, color: Color(0xFF5E5CE6)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurface)),
              ),
              if (c.joiningHelper)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (paired)
                Switch(value: c.helperOn, onChanged: c.setHelperOn)
              else
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                  child: Icon(Icons.chevron_right_rounded, size: 20),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Computer: the phones this computer is scanning for, live: how far each
/// scan is, how fast it goes (all of it and the part done here), what's
/// left, and the results remembered for that phone (its own setting).
class ScanHelperDashboard extends StatefulWidget {
  const ScanHelperDashboard({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ScanHelperDashboard> createState() => _ScanHelperDashboardState();
}

class _ScanHelperDashboardState extends State<ScanHelperDashboard> {
  ScanHelperHub? get _hub => widget.controller.scanHelper;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _hub?.addListener(_refresh);
    // Speeds and "last photo" times move on even between photos.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _hub?.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hub = _hub;
    final scheme = Theme.of(context).colorScheme;
    final sessions = [...?hub?.sessions.values]..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return Scaffold(
      appBar: AppBar(title: const Text('Scanning for phones')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        if (hub == null || !hub.allowed)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Text('Helping phones scan is turned off (Settings › General).',
                style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
          )
        else if (sessions.isEmpty)
          SectionCard(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const IconTile(icon: Icons.memory_rounded, color: Color(0xFF5E5CE6)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'No phone is scanning with this computer right now. Start a scan on a paired phone '
                  '(Settings › Scan with my computer) on this Wi‑Fi, and it shows up here.',
                  style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
                ),
              ),
            ]),
          )
        else
          for (final s in sessions) _SessionPanel(hub: hub, session: s),
      ]),
    );
  }
}

class _SessionPanel extends StatelessWidget {
  const _SessionPanel({required this.hub, required this.session});

  final ScanHelperHub hub;
  final ScanHelpSession session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final since = DateTime.now().difference(s.lastSeen);
    final working = since < const Duration(seconds: 5);
    final done = s.phoneDone, total = s.phoneTotal;
    final left = s.remaining, timeLeft = s.timeLeft, share = s.share, ms = s.msPerPhoto;
    String photos(int n) => '$n ${n == 1 ? 'photo' : 'photos'}';
    final metrics = <(IconData, Color, String, String)>[
      (Icons.speed_rounded, const Color(0xFF34C759), s.phoneRate == null ? '–' : formatRate(s.phoneRate!),
          'photos/s, whole scan'),
      (Icons.memory_rounded, const Color(0xFF5E5CE6), formatRate(s.rate), 'photos/s on this computer'),
      (Icons.photo_library_rounded, const Color(0xFF0A84FF), '${s.photos}',
          share == null ? 'scanned here' : 'scanned here (${(share * 100).round()}%)'),
      (Icons.face_rounded, const Color(0xFFFF9F0A), '${s.faces}', 'faces found here'),
      (Icons.timer_outlined, const Color(0xFF30B0C7), ms == null ? '–' : '$ms ms', 'per photo here'),
      (Icons.download_rounded, const Color(0xFF8E8E93), _size(s.bytes), 'received'),
      if (s.keepDays > 0) (Icons.history_rounded, const Color(0xFFAF52DE), '${s.remembered}', 'answered from memory'),
      if (s.failed > 0) (Icons.error_outline_rounded, const Color(0xFFFF453A), '${s.failed}', 'failed'),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionCard(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const IconTile(icon: Icons.smartphone_rounded, color: Color(0xFF0A84FF)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Scanning for ${s.alias}',
                      style: const TextStyle(fontSize: TextSize.headline, fontWeight: FontWeight.w700)),
                  Text(
                    [
                      ?s.album,
                      working
                          ? 'working'
                          : s.active
                              ? 'waiting for the phone · last photo ${since.inSeconds} s ago'
                              : 'stopped sending · last photo ${_ago(since)} ago',
                      'connected ${_ago(DateTime.now().difference(s.started))}',
                    ].join(' · '),
                    style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
                  ),
                ]),
              ),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: working ? const Color(0xFF34C759) : scheme.outlineVariant,
                ),
              ),
            ]),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              Text(done == null ? '–' : '$done',
                  style: text.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 8),
              Expanded(
                child: Text(total == null ? 'photos done on the phone' : 'of ${photos(total)} done',
                    style: TextStyle(fontSize: TextSize.body, color: scheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: done == null || total == null || total == 0 ? null : done / total,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              left == null
                  ? 'Waiting for the phone to say how many photos it has'
                  : left == 0
                      ? 'All photos done'
                      : '${photos(left)} left${timeLeft == null ? '' : ' · about ${_ago(timeLeft)} to go'}',
              style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(builder: (context, box) {
          final perRow = math.max(2, (box.maxWidth / 190).floor());
          final w = (box.maxWidth - (perRow - 1) * 10) / perRow;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final (icon, color, value, label) in metrics)
              SizedBox(
                width: w,
                child: SectionCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    IconTile(icon: icon, color: color),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(value,
                          style: const TextStyle(
                              fontSize: TextSize.title3,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                    Text(label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ),
          ]);
        }),
        const SectionHeader(title: 'Remembered results'),
        SectionCard.rows(rows: [
          SectionRow(
            leading: const IconTile(icon: Icons.history_rounded, color: Color(0xFFAF52DE)),
            title: s.keepDays == 0
                ? 'Not kept'
                : 'Kept for ${s.keepDays == 1 ? '1 day' : '${s.keepDays} days'}',
            subtitle: s.keepDays == 0
                ? '${s.alias} doesn\'t let this computer keep its face results (its Settings choose)'
                : '${s.keptCount} ${s.keptCount == 1 ? 'photo' : 'photos'} · ${_size(s.keptBytes)} · '
                    'set on ${s.alias}; only face results, never the photos',
          ),
          if (s.keptCount > 0)
            SectionRow(
              leading: const IconTile(icon: Icons.delete_outline_rounded, color: Color(0xFFFF453A)),
              title: 'Delete remembered results now',
              destructive: true,
              onTap: () => hub.forgetResults(s),
            ),
          SectionRow(
            leading: const IconTile(icon: Icons.stop_circle_outlined, color: Color(0xFFFF453A)),
            title: 'Stop helping ${s.alias}',
            subtitle: 'The phone carries on scanning by itself',
            destructive: true,
            onTap: () => hub.stop(s),
          ),
        ]),
      ]),
    );
  }
}

String _size(int bytes) => bytes >= 1e9
    ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
    : bytes >= 1e6
        ? '${(bytes / 1e6).toStringAsFixed(bytes < 1e7 ? 1 : 0)} MB'
        : '${(bytes / 1e3).ceil()} KB';

String _ago(Duration d) => d.inHours > 0
    ? '${d.inHours} h ${d.inMinutes % 60} min'
    : d.inMinutes > 0
        ? '${d.inMinutes} min'
        : '${d.inSeconds} s';
