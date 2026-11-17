import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/people_sync.dart';
import '../scan/scan_controller.dart';
import '../share/people_link.dart';
import '../share/protocol.dart';
import 'desktop_layout.dart';
import 'island.dart';
import 'sections.dart';
import 'theme.dart';

/// Swap who's who with your other devices (phone ↔ laptop, phone ↔ phone):
/// names and face fingerprints only, never photos. Both devices end up
/// knowing everyone either one has named, so a scan on either recognises
/// them without marking anyone twice.
class PeopleSyncScreen extends StatefulWidget {
  const PeopleSyncScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<PeopleSyncScreen> createState() => _PeopleSyncScreenState();
}

class _PeopleSyncScreenState extends State<PeopleSyncScreen> {
  ScanController get c => widget.controller;

  late final Future<List<SyncPersonRow>> _mine = c.db.peopleForSync();

  /// The device being swapped with, and the code it should show.
  LsDevice? _with;
  String? _code;
  SwapOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    c.sharing.discovery.addListener(_refresh);
  }

  @override
  void dispose() {
    c.sharing.discovery.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// ShareBro phones and computers on this network (not plain LocalSend).
  List<LsDevice> get _devices => [
        for (final d in c.sharing.discovery.devices)
          if (d.info.deviceModel == 'ShareBro' && d.fingerprint != c.sharing.identity.fingerprint) d,
      ];

  Future<void> _swap(LsDevice d) async {
    final code = PeopleSyncHub.newCode();
    setState(() {
      _with = d;
      _code = code;
      _outcome = null;
    });
    final outcome = await c.peopleSync.swapWith(d, code);
    if (!mounted) return;
    setState(() => _outcome = outcome);
  }

  @override
  Widget build(BuildContext context) {
    final pad = DesktopLayout.pad(context, const EdgeInsets.fromLTRB(16, 8, 16, 32));
    return Scaffold(
      appBar: AppBar(title: const Text('Sync people')),
      body: ListView(padding: pad, children: [
        const _Intro(),
        FutureBuilder<List<SyncPersonRow>>(
          future: _mine,
          builder: (context, snap) => _MyPeople(people: snap.data),
        ),
        if (_with != null) ...[
          const SectionHeader(title: 'Swapping'),
          _Progress(device: _with!, code: _code!, outcome: _outcome, controller: c),
        ],
        SectionHeader(
          title: 'Your devices nearby',
          trailing: _with != null && _outcome == null
              ? null
              : const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        if (_devices.isEmpty)
          const SectionCard(
            padding: EdgeInsets.all(16),
            child: Text('Looking for your other devices… Open ShareBro on your other phone or computer, '
                'on the same Wi-Fi or hotspot as this one.'),
          )
        else
          SectionCard.rows(rows: [
            for (final d in _devices)
              SectionRow(
                leading: IconTile(
                  icon: d.info.deviceType == LsDeviceType.desktop ? Icons.laptop_rounded : Icons.smartphone_rounded,
                  color: const Color(0xFF0A84FF),
                ),
                title: d.alias,
                subtitle: 'Swap people with this device',
                chevron: true,
                enabled: _with == null || _outcome != null,
                onTap: () => _swap(d),
              ),
          ]),
        const SectionFooter(
          'Only names and face fingerprints are swapped: lists of numbers that recognise a face. '
          'No photos, file names, dates or places leave this device, and the other device has to accept.',
        ),
      ]),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const IconTile(icon: Icons.sync_alt_rounded, color: Color(0xFF30D158)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Name people once, on any device',
                style: TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'Swap who\'s who with your other phone or computer. Both end up knowing everyone either one has named, '
              'and their scans recognise them from then on.',
              style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// The named people this device would send.
class _MyPeople extends StatelessWidget {
  const _MyPeople({required this.people});

  final List<SyncPersonRow>? people;

  @override
  Widget build(BuildContext context) {
    final p = people;
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        title: 'From this device',
        badge: p == null ? null : Text('${p.length}', style: TextStyle(color: scheme.onSurfaceVariant)),
      ),
      SectionCard(
        padding: const EdgeInsets.all(14),
        child: p == null
            ? const SizedBox(height: 40, child: Center(child: CircularProgressIndicator()))
            : p.isEmpty
                ? const Text('No named people here yet. You can still swap: this device will learn the other one\'s people.')
                : Wrap(spacing: 10, runSpacing: 10, children: [
                    for (final person in p.take(40)) _Face(thumb: person.thumb, name: person.name),
                    if (p.length > 40)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text('+${p.length - 40} more', style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                  ]),
      ),
    ]);
  }
}

class _Face extends StatelessWidget {
  const _Face({required this.thumb, required this.name});

  final Uint8List? thumb;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = thumb;
    return SizedBox(
      width: 64,
      child: Column(children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: scheme.surfaceContainerHighest,
          backgroundImage: t == null ? null : MemoryImage(t),
          child: t == null ? Icon(Icons.person, color: scheme.outline) : null,
        ),
        const SizedBox(height: 4),
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: TextSize.small)),
      ]),
    );
  }
}

/// Waiting for the other device, then what came of it.
class _Progress extends StatelessWidget {
  const _Progress({required this.device, required this.code, required this.outcome, required this.controller});

  final LsDevice device;
  final String code;
  final SwapOutcome? outcome;
  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = outcome;
    if (o == null) {
      return SectionCard(
        padding: const EdgeInsets.all(18),
        child: Column(children: [
          Text('Accept on ${device.alias}', style: const TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('It should show this code:', style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Text(code,
              style: TextStyle(
                  fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 10, color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ]),
      );
    }
    final (icon, color, text) = switch (o.status) {
      SwapStatus.done => (Icons.check_circle_rounded, const Color(0xFF30D158), _summary(o.result!)),
      SwapStatus.declined => (Icons.block_rounded, scheme.error, '${device.alias} didn\'t accept. Nothing was swapped.'),
      SwapStatus.busy => (Icons.hourglass_top_rounded, scheme.error, '${device.alias} is answering another swap. Try again in a moment.'),
      SwapStatus.notSharebro =>
        (Icons.system_update_rounded, scheme.error, '${device.alias} needs a newer ShareBro (1.8 or later) to swap people.'),
      SwapStatus.failed => (Icons.wifi_off_rounded, scheme.error, 'Couldn\'t reach ${device.alias}. Check both are on the same Wi-Fi and try again.'),
    };
    final conflicts = o.result?.conflicts ?? const <NameConflict>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      ),
      if (conflicts.isNotEmpty) ...[
        const SectionHeader(title: 'Different names'),
        NameConflicts(controller: controller, conflicts: conflicts),
      ],
    ]);
  }
}

String _summary(PeopleSyncResult r) {
  if (r.wrongModel) {
    return '${r.from} uses a different face model, so its people couldn\'t be taken in. Update ShareBro on both devices.';
  }
  final parts = [
    if (r.added > 0) '${r.added} new ${r.added == 1 ? 'person' : 'people'}',
    if (r.matched > 0) '${r.matched} already here',
    if (r.named > 0) '${r.named} named',
  ];
  return parts.isEmpty
      ? 'Swapped with ${r.from}. It had no named people to send; it now knows yours.'
      : 'Swapped with ${r.from}: ${parts.join(', ')}. Scans here recognise them from now on.';
}

/// "Rubi here, Ruby there": pick the name to keep, one person at a time.
class NameConflicts extends StatefulWidget {
  const NameConflicts({super.key, required this.controller, required this.conflicts});

  final ScanController controller;
  final List<NameConflict> conflicts;

  @override
  State<NameConflicts> createState() => _NameConflictsState();
}

class _NameConflictsState extends State<NameConflicts> {
  final Map<int, String> _chosen = {};

  Future<void> _use(NameConflict n, String name) async {
    if (name != n.localName) await widget.controller.db.setPersonNames(n.localId, name: name);
    widget.controller.changed();
    setState(() => _chosen[n.localId] = name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SectionCard.rows(rows: [
      for (final n in widget.conflicts)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: scheme.surfaceContainerHighest,
              backgroundImage: n.thumb == null ? null : MemoryImage(n.thumb!),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _chosen[n.localId] != null
                  ? Text('Called "${_chosen[n.localId]}"')
                  : Text('"${n.localName}" here, "${n.theirName}" there', maxLines: 2),
            ),
            if (_chosen[n.localId] == null) ...[
              TextButton(onPressed: () => _use(n, n.localName), child: Text('Keep ${n.localName}')),
              FilledButton.tonal(onPressed: () => _use(n, n.theirName), child: Text('Use ${n.theirName}')),
            ],
          ]),
        ),
    ]);
  }
}

/// Wraps the app: when another of your devices asks to swap people, asks
/// here whether to accept (showing who they'd send and the code), and then
/// says what came in.
class PeopleSyncWatcher extends StatefulWidget {
  const PeopleSyncWatcher({super.key, required this.controller, required this.child});

  final ScanController controller;
  final Widget child;

  @override
  State<PeopleSyncWatcher> createState() => _PeopleSyncWatcherState();
}

class _PeopleSyncWatcherState extends State<PeopleSyncWatcher> {
  IncomingPeopleRequest? _shown;
  PeopleSyncResult? _reported;

  PeopleSyncHub get _hub => widget.controller.peopleSync;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_check);
  }

  @override
  void dispose() {
    _hub.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final req = _hub.pending;
    if (req != null && req != _shown && !req.answered) {
      _shown = req;
      _ask(req);
    }
    final done = _hub.lastIncoming;
    if (done != null && done != _reported) {
      _reported = done;
      _report(done);
    }
  }

  Future<void> _ask(IncomingPeopleRequest req) async {
    final nav = islandNavigator.currentState;
    final ctx = nav?.context ?? context;
    final yes = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) => _AskDialog(request: req),
    );
    req.answer(yes ?? false);
  }

  void _report(PeopleSyncResult r) {
    Island.toast(r.wrongModel ? 'Couldn\'t take people from ${r.from}' : 'People swapped with ${r.from}',
        icon: r.wrongModel ? Icons.error_outline_rounded : Icons.sync_alt_rounded);
    if (r.conflicts.isEmpty) return;
    final nav = islandNavigator.currentState;
    final ctx = nav?.context ?? context;
    showModalBottomSheet<void>(
      context: ctx,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Different names from ${r.from}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('The same person has another name on the other device. Pick the one to use here.'),
            const SizedBox(height: 12),
            Flexible(child: SingleChildScrollView(child: NameConflicts(controller: widget.controller, conflicts: r.conflicts))),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _AskDialog extends StatelessWidget {
  const _AskDialog({required this.request});

  final IncomingPeopleRequest request;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = request;
    final n = r.people.length;
    return AlertDialog(
      icon: const Icon(Icons.sync_alt_rounded),
      title: Text('${r.from} wants to swap people'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(n == 0
              ? 'It has no named people yet; it would learn the people named here.'
              : 'It would send $n named ${n == 1 ? 'person' : 'people'} and learn the people named here. '
                  'Names and face fingerprints only, no photos.'),
          if (n > 0) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in r.people.take(12)) _Face(thumb: p.thumb, name: p.name),
              if (n > 12) Padding(padding: const EdgeInsets.only(top: 14), child: Text('+${n - 12}')),
            ]),
          ],
          const SizedBox(height: 14),
          Center(
            child: Text(r.code,
                style: TextStyle(
                    fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 8, color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 6),
          Text('Accept only if you started this on your other device and it shows the same code.',
              style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
      ],
    );
  }
}
