import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/people_sync.dart';
import '../scan/scan_controller.dart';
import '../share/people_link.dart';
import '../share/protocol.dart';
import 'desktop_layout.dart';
import 'glass.dart';
import 'island.dart';
import 'sections.dart';
import 'theme.dart';
import 'face_image.dart';

/// Swap who's who with your other devices (phone ↔ laptop, phone ↔ phone):
/// names and face fingerprints only, never photos. Both devices end up
/// knowing the people each one chose to share, so a scan on either
/// recognises them without marking anyone twice.
class PeopleSyncScreen extends StatefulWidget {
  const PeopleSyncScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<PeopleSyncScreen> createState() => _PeopleSyncScreenState();
}

class _PeopleSyncScreenState extends State<PeopleSyncScreen> {
  ScanController get c => widget.controller;

  /// This device's named people, and the ones not to share (by sync id).
  List<SyncPersonRow>? _mine;
  Set<String> _skipped = {};
  String _filter = '';

  /// The device being swapped with, and the code it should show.
  LsDevice? _with;
  String? _code;
  SwapOutcome? _outcome;

  @override
  void initState() {
    super.initState();
    c.sharing.discovery.addListener(_refresh);
    _load();
  }

  Future<void> _load() async {
    final mine = await c.db.peopleForSync();
    final skipped = await c.peopleSyncSkipped();
    if (mounted) {
      setState(() {
        _mine = mine;
        _skipped = skipped;
      });
    }
  }

  @override
  void dispose() {
    c.sharing.discovery.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _setSkipped(Set<String> skipped) {
    setState(() => _skipped = skipped);
    c.setPeopleSyncSkipped(skipped);
  }

  int get _sharedCount => (_mine ?? const []).where((p) => !_skipped.contains(p.syncId)).length;

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

  Widget _chooser() => _PeopleChooser(
        people: _mine,
        skipped: _skipped,
        filter: _filter,
        onFilter: (f) => setState(() => _filter = f),
        onChanged: _setSkipped,
      );

  /// Swapping now (or how it went), then the devices to swap with.
  List<Widget> _devicesPart() {
    final busy = _with != null && _outcome == null;
    final n = _sharedCount;
    return [
      if (_with != null) ...[
        const SectionHeader(title: 'Swapping', top: 4),
        _Progress(device: _with!, code: _code!, outcome: _outcome, controller: c),
      ],
      SectionHeader(
        title: 'Your devices nearby',
        top: _with == null ? 4 : 26,
        trailing: busy ? null : const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      if (_devices.isEmpty)
        SectionCard(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const IconTile(icon: Icons.wifi_find_rounded, color: Color(0xFF8E8E93)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Looking for your other devices… Open ShareBro on your other phone or computer, '
                'on the same Wi‑Fi or hotspot as this one.',
                style: TextStyle(fontSize: TextSize.caption, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ]),
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
              subtitle: n == 0
                  ? 'Learn its people (you share nobody)'
                  : 'Share $n ${n == 1 ? 'person' : 'people'}, learn its people',
              trailing: busy && _with == d
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('Swap', style: TextStyle(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
              enabled: !busy,
              onTap: () => _swap(d),
            ),
        ]),
      const SectionFooter(
        'Only names and face fingerprints are swapped: lists of numbers that recognise a face. '
        'No photos, file names, dates or places leave this device, and the other device has to accept '
        '(and can choose which of your people to take).',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopLayout.on) {
      final pad = DesktopLayout.pad(context, const EdgeInsets.fromLTRB(16, 8, 16, 32));
      return Scaffold(
        appBar: AppBar(title: const Text('Sync people')),
        body: ListView(padding: pad, children: [
          const _Intro(),
          const SizedBox(height: 18),
          _chooser(),
          const SizedBox(height: 18),
          ..._devicesPart(),
        ]),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Desktop: who to share on the left, the devices and the swap on the right.
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 24, 10),
          child: Row(children: [
            GlassIconButton(
              tooltip: 'Back (Esc)',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.maybePop(context),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Sync people', style: text.headlineSmall),
                Text('Name people once, on any of your devices. Names and face fingerprints only, never photos.',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 900;
            if (!wide) {
              return ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 32), children: [
                _chooser(),
                const SizedBox(height: 18),
                ..._devicesPart(),
              ]);
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _chooser()),
                const SizedBox(width: 20),
                SizedBox(
                  width: 380,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _devicesPart()),
                ),
              ]),
            );
          }),
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
              'Swap who\'s who with your other phone or computer. Pick who to share below; '
              'both devices recognise them in scans from then on.',
              style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// This device's named people, each ticked to share or not, with Select
/// all / none and a search when there are many.
class _PeopleChooser extends StatelessWidget {
  const _PeopleChooser({
    required this.people,
    required this.skipped,
    required this.filter,
    required this.onFilter,
    required this.onChanged,
  });

  final List<SyncPersonRow>? people;
  final Set<String> skipped;
  final String filter;
  final ValueChanged<String> onFilter;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = people;
    if (all == null) {
      return const SectionCard(
        padding: EdgeInsets.all(24),
        child: SizedBox(height: 40, child: Center(child: CircularProgressIndicator())),
      );
    }
    final shared = all.where((p) => !skipped.contains(p.syncId)).length;
    final q = filter.trim().toLowerCase();
    final shown = q.isEmpty
        ? all
        : [for (final p in all) if (p.name.toLowerCase().contains(q) || (p.nickname?.toLowerCase().contains(q) ?? false)) p];
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('People to share', style: TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          if (all.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text('$shared of ${all.length}',
                  style: TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600, color: scheme.primary)),
            ),
          const Spacer(),
          if (all.isNotEmpty) ...[
            TextButton(
              onPressed: shared == all.length ? null : () => onChanged({}),
              child: const Text('Select all'),
            ),
            TextButton(
              onPressed: shared == 0 ? null : () => onChanged({for (final p in all) p.syncId}),
              child: const Text('Select none'),
            ),
          ],
        ]),
        Text(
          all.isEmpty
              ? 'No named people here yet. You can still swap: this device will learn the other one\'s people.'
              : 'Click a face to share it or keep it on this device. Only ticked people are sent.',
          style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant),
        ),
        if (all.length > 12) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 36,
            child: TextField(
              onChanged: onFilter,
              decoration: const InputDecoration(
                hintText: 'Find a person',
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ],
        if (shown.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(spacing: 6, runSpacing: 12, children: [
            for (final p in shown)
              _PickFace(
                thumb: p.thumb,
                name: p.name,
                selected: !skipped.contains(p.syncId),
                onTap: () => onChanged(
                    skipped.contains(p.syncId) ? ({...skipped}..remove(p.syncId)) : {...skipped, p.syncId}),
              ),
          ]),
        ] else if (all.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text('Nobody called "$filter".', style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// A face that can be ticked (shared or taken) or not: ticked ones carry a
/// ring and a tick, the others fade back.
class _PickFace extends StatelessWidget {
  const _PickFace({required this.thumb, required this.name, required this.selected, required this.onTap, this.size = 26});

  final Uint8List? thumb;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = thumb;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: size * 2 + 22,
            child: Column(children: [
              Stack(clipBehavior: Clip.none, children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? scheme.primary : Colors.transparent,
                  ),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: selected ? 1 : 0.4,
                    child: CircleAvatar(
                      radius: size,
                      backgroundColor: scheme.surfaceContainerHighest,
                      backgroundImage: t == null ? null : FaceImage(t),
                      child: t == null ? Icon(Icons.person, color: scheme.outline) : null,
                    ),
                  ),
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? scheme.primary : Mac.card(context),
                      border: Border.all(color: selected ? Mac.card(context) : scheme.outline, width: 1.5),
                    ),
                    child: selected ? Icon(Icons.check_rounded, size: 13, color: scheme.onPrimary) : null,
                  ),
                ),
              ]),
              const SizedBox(height: 5),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: TextSize.small,
                    color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  )),
            ]),
          ),
        ),
      ),
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
              backgroundImage: n.thumb == null ? null : FaceImage(n.thumb!),
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
    // Null: declined; otherwise the people (sync ids) to take in.
    final take = await showDialog<Set<String>>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) => _AskDialog(request: req),
    );
    req.answer(take != null, only: take);
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

/// Another device asks to swap: who it would send (each can be unticked),
/// the code to compare, Decline or Take.
class _AskDialog extends StatefulWidget {
  const _AskDialog({required this.request});

  final IncomingPeopleRequest request;

  @override
  State<_AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<_AskDialog> {
  late final Set<String> _take = {for (final p in widget.request.people) p.syncId};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.request;
    final n = r.people.length;
    final picked = _take.length;
    return AlertDialog(
      icon: const Icon(Icons.sync_alt_rounded),
      title: Text('${r.from} wants to swap people'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(n == 0
              ? 'It has no named people to send; it would learn the people you share from here.'
              : 'It would send $n named ${n == 1 ? 'person' : 'people'} and learn the people you share from here. '
                  'Names and face fingerprints only, no photos. Untick anyone you don\'t want here.'),
          if (n > 0) ...[
            const SizedBox(height: 8),
            Row(children: [
              Text('$picked of $n to take', style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
              const Spacer(),
              TextButton(
                onPressed: picked == n ? null : () => setState(() => _take.addAll(r.people.map((p) => p.syncId))),
                child: const Text('All'),
              ),
              TextButton(onPressed: picked == 0 ? null : () => setState(_take.clear), child: const Text('None')),
            ]),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: Wrap(spacing: 4, runSpacing: 10, children: [
                  for (final p in r.people)
                    _PickFace(
                      thumb: p.thumb,
                      name: p.name,
                      size: 22,
                      selected: _take.contains(p.syncId),
                      onTap: () => setState(() => _take.contains(p.syncId) ? _take.remove(p.syncId) : _take.add(p.syncId)),
                    ),
                ]),
              ),
            ),
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
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Decline')),
        FilledButton(
          onPressed: () => Navigator.pop(context, Set<String>.of(_take)),
          child: Text(n == 0 || picked == n ? 'Accept' : 'Accept · take $picked'),
        ),
      ],
    );
  }
}
