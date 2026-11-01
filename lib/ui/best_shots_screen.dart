import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/group_shots.dart';
import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import 'aurora.dart';
import 'glass.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'sections.dart';
import 'send_to_sheet.dart';
import 'widgets.dart';

/// Group photos taken seconds apart, with the shot where everyone's eyes
/// are open (and most people smile) picked out. Keeping it hides the
/// others in the app; nothing is deleted.
class BestShotsScreen extends StatefulWidget {
  const BestShotsScreen({super.key, required this.controller, this.tripId});

  final ScanController controller;
  final int? tripId;

  @override
  State<BestShotsScreen> createState() => _BestShotsScreenState();
}

class _BestShotsScreenState extends State<BestShotsScreen> {
  ScanController get c => widget.controller;
  List<ShotBurst>? _bursts;

  /// The user's own pick per burst (burst's first asset id -> index).
  final Map<String, int> _pick = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bursts = findBursts(await c.db.groupShots(tripId: widget.tripId));
    if (mounted) setState(() => _bursts = bursts);
  }

  int _keeper(ShotBurst b) => _pick[b.shots.first.assetId] ?? b.best;

  List<String> _others(ShotBurst b) => [
        for (final (i, s) in b.shots.indexed)
          if (i != _keeper(b)) s.assetId,
      ];

  Future<void> _keep(List<ShotBurst> bursts) async {
    final ids = [for (final b in bursts) ..._others(b)];
    await c.db.setHidden(ids, true);
    Haptics.success();
    c.changed();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Kept the best, hid ${ids.length} other ${ids.length == 1 ? 'shot' : 'shots'} in the app'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await c.db.setHidden(ids, false);
            c.changed();
            await _load();
          },
        ),
      ));
  }

  void _open(ShotBurst b, int i) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(ids: [for (final s in b.shots) s.assetId], initial: i, controller: c),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bursts = _bursts;
    final extra = bursts?.fold<int>(0, (n, b) => n + b.shots.length - 1) ?? 0;
    return Aurora(
      intensity: 0.6,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassScrollView(
          title: 'Best group shots',
          subtitle: bursts == null || bursts.isEmpty
              ? null
              : '${bursts.length} ${bursts.length == 1 ? 'moment' : 'moments'} · $extra extra shots',
          slivers: [
            if (bursts == null)
              const SliverFillRemaining(child: PhotosSkeleton(columns: 2))
            else if (bursts.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyIllustration(
                  message: 'No group bursts yet.\n'
                      'When you take a few group photos in a row, the one with everyone\'s eyes open shows up here.',
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
                sliver: SliverList.list(children: [
                  SectionCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const IconTile(icon: Icons.auto_awesome_rounded, color: Color(0xFFFF9F0A)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            'For each moment, the shot with open eyes, smiles and sharp faces is picked. '
                            'Tap another shot to keep that one instead; press and hold to look closer.',
                            style: TextStyle(
                                fontSize: 13.5, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                        onPressed: () => _keep(bursts),
                        icon: const Icon(Icons.done_all_rounded),
                        label: const Text('Keep the best of every moment'),
                      ),
                    ]),
                  ),
                  for (final (i, b) in bursts.indexed)
                    Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: _BurstCard(
                        burst: b,
                        keeper: _keeper(b),
                        onPick: (k) {
                          Haptics.tick();
                          setState(() => _pick[b.shots.first.assetId] = k);
                        },
                        onOpen: (k) => _open(b, k),
                        onKeep: () => _keep([b]),
                        onSend: () => showSendToSheet(context,
                            controller: c, items: [SendItem.asset(b.shots[_keeper(b)].assetId)]),
                      ),
                    ).animate().fadeIn(delay: (40 * i.clamp(0, 8)).ms).moveY(begin: 12, curve: Curves.easeOutCubic),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _BurstCard extends StatelessWidget {
  const _BurstCard({
    required this.burst,
    required this.keeper,
    required this.onPick,
    required this.onOpen,
    required this.onKeep,
    required this.onSend,
  });

  final ShotBurst burst;
  final int keeper;
  final ValueChanged<int> onPick, onOpen;
  final VoidCallback onKeep, onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shot = burst.shots[keeper];
    final picked = keeper == burst.best;
    final at = DateTime.fromMillisecondsSinceEpoch(burst.shots.first.shot.takenAt);
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: () => onOpen(keeper),
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(fit: StackFit.expand, children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: AssetThumb(key: ValueKey(shot.assetId), id: shot.assetId, size: 800),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: picked ? scheme.primary : Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(picked ? Icons.auto_awesome_rounded : Icons.touch_app_rounded,
                        size: 15, color: picked ? scheme.onPrimary : Colors.white),
                    const SizedBox(width: 5),
                    Text(picked ? 'Best' : 'Your pick',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: picked ? scheme.onPrimary : Colors.white)),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(picked ? burst.reason : _issues(shot),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${burst.shots.length} shots · ${shot.faceCount} people · ${formatDay(at)}, ${formatTime(at)}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ]),
        ),
        SizedBox(
          height: 84,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            children: [
              for (final (i, s) in burst.shots.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Pressable(
                    onTap: () => onPick(i),
                    onLongPress: () => onOpen(i),
                    child: Semantics(
                      selected: i == keeper,
                      label: 'Shot ${i + 1}${s.blinks > 0 ? ', ${s.blinks} blinking' : ''}',
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 64,
                        padding: const EdgeInsets.all(2.5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: i == keeper ? scheme.primary : Colors.transparent, width: 2.5),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(fit: StackFit.expand, children: [
                            AssetThumb(id: s.assetId, size: 160),
                            if (s.blinks > 0)
                              Positioned(
                                right: 3,
                                bottom: 3,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.65),
                                      borderRadius: BorderRadius.circular(99)),
                                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                                    const Icon(Icons.visibility_off_rounded, size: 11, color: Colors.white),
                                    const SizedBox(width: 2),
                                    Text('${s.blinks}',
                                        style: const TextStyle(
                                            fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w700)),
                                  ]),
                                ),
                              ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: onKeep,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Keep this one'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Send this shot',
              onPressed: onSend,
              icon: const Icon(Icons.send_rounded),
            ),
          ]),
        ),
      ]),
    );
  }

  static String _issues(ScoredShot s) {
    final bits = [
      if (s.blinks > 0) '${s.blinks} blinking',
      if (s.blurry > 0) '${s.blurry} blurry',
    ];
    return bits.isEmpty ? 'Your pick' : 'Your pick · ${bits.join(', ')}';
  }
}
