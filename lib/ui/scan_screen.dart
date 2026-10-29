import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'motion.dart';
import 'review_screen.dart';
import 'aurora.dart';
import 'widgets.dart';

/// Full-screen scan progress: a rolling photo count and a live stream of
/// faces popping in as they're found, then a celebration when done.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  ScanController get c => widget.controller;
  Future<List<PersonSummary>>? _people;
  Future<int>? _reviewCount;
  StreamSubscription<String>? _milestoneSub;
  String? _milestone;
  int _milestoneCount = 0;
  Timer? _milestoneHide;
  bool _wasRunning = false;

  @override
  void initState() {
    super.initState();
    _wasRunning = c.running;
    c.addListener(_onChange);
    _milestoneSub = c.milestones.listen(_showMilestone);
    if (!c.running) _loadResults();
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    _milestoneSub?.cancel();
    _milestoneHide?.cancel();
    super.dispose();
  }

  void _onChange() {
    if (!c.running && _people == null) _loadResults();
    if (_wasRunning && !c.running) Haptics.success();
    _wasRunning = c.running;
    setState(() {});
  }

  void _showMilestone(String text) {
    Haptics.success();
    _milestoneHide?.cancel();
    setState(() {
      _milestone = text;
      _milestoneCount++;
    });
    _milestoneHide = Timer(2400.ms, () {
      if (mounted) setState(() => _milestone = null);
    });
  }

  void _loadResults() {
    _people = c.db.people(tripId: c.tripId);
    _reviewCount = c.reviewQueue().then((q) => q.length);
  }

  @override
  Widget build(BuildContext context) {
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(c.albumName ?? 'Scan')),
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: 500.ms,
              switchInCurve: Curves.easeOutCubic,
              child: c.running ? _running(context) : _finished(context),
            ),
            if (_milestone != null)
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: _MilestonePill(
                    key: ValueKey(_milestoneCount),
                    text: _milestone!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _running(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final eta = c.eta;
    return Column(
      key: const ValueKey('running'),
      children: [
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            RollingCount(
              value: c.done,
              style: text.displayMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text('of ${c.total} photos', style: text.titleMedium),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 10, 32, 8),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: c.total == 0 ? 0 : c.done / c.total),
            duration: 400.ms,
            builder: (_, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: v, minHeight: 10),
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            Chip(
              avatar: const Icon(Icons.face, size: 18),
              label: Text('${c.facesFound} faces'),
            ),
            if (c.peopleSoFar > 0)
              Chip(
                    avatar: const Icon(Icons.groups_outlined, size: 18),
                    label: Text('≈ ${c.peopleSoFar} people so far'),
                  )
                  // Pops every time a new person turns up.
                  .animate(key: ValueKey(c.peopleSoFar))
                  .scaleXY(
                    begin: 1.25,
                    duration: 450.ms,
                    curve: Curves.elasticOut,
                  ),
            if (eta != null)
              Chip(
                avatar: const Icon(Icons.schedule, size: 18),
                label: Text(
                  eta.inMinutes > 0
                      ? '~${eta.inMinutes} min left'
                      : '~${eta.inSeconds} s left',
                ),
              ),
          ],
        ),
        if (c.preview != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: _LivePreview(controller: c),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
          child: Text(
            'You can lock your phone — scanning continues in the background.',
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final thumb in c.recentFaces)
                  ClipOval(
                        key: ObjectKey(thumb),
                        child: Image.memory(
                          thumb,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                        ),
                      )
                      .animate()
                      .scale(
                        begin: const Offset(0.2, 0.2),
                        duration: 500.ms,
                        curve: Curves.elasticOut,
                      )
                      .fadeIn(duration: 200.ms),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: c.cancel,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Stop scanning'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _finished(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder<List<PersonSummary>>(
      key: const ValueKey('finished'),
      future: _people,
      builder: (context, snap) {
        final people = snap.data;
        if (people == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            const SizedBox(height: 24),
            SizedBox(
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const ConfettiBurst(count: 56),
                  Text(
                    '🎉',
                    style: const TextStyle(fontSize: 72),
                  ).animate().scale(
                    begin: const Offset(0, 0),
                    duration: 700.ms,
                    curve: Curves.elasticOut,
                  ),
                ],
              ),
            ),
            Text(
              'Found ${people.length} people',
              style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ).animate().fadeIn(delay: 200.ms).moveY(begin: 12),
            Text(
              'in ${c.done} photos · ${c.facesFound} new faces',
              style: text.bodyMedium,
            ).animate().fadeIn(delay: 300.ms),
            const SizedBox(height: 24),
            // Finale: the faces burst out of the 🎉 and settle into a grid.
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  const pad = 24.0, gap = 12.0;
                  final cols = ((box.maxWidth - 2 * pad + gap) / (76 + gap))
                      .floor()
                      .clamp(3, 8);
                  final tile =
                      (box.maxWidth - 2 * pad - (cols - 1) * gap) / cols;
                  // Where the 🎉 is, relative to the top of this grid.
                  final burst = Offset(box.maxWidth / 2, -170);
                  return GridView.builder(
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.symmetric(horizontal: pad),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                    ),
                    itemCount: people.length,
                    itemBuilder: (context, i) {
                      final spot = Offset(
                        pad + (i % cols) * (tile + gap) + tile / 2,
                        (i ~/ cols) * (tile + gap) + tile / 2,
                      );
                      final delay = (250 + 40 * i.clamp(0, 30)).ms;
                      return FaceAvatar(
                            personId: people[i].id,
                            thumb: people[i].coverThumb,
                            radius: 34,
                            hero: false,
                          )
                          .animate()
                          .fadeIn(delay: delay, duration: 150.ms)
                          .move(
                            begin: burst - spot,
                            end: Offset.zero,
                            delay: delay,
                            duration: 750.ms,
                            curve: Curves.easeOutBack,
                          )
                          .scaleXY(
                            begin: 0.2,
                            delay: delay,
                            duration: 750.ms,
                            curve: Curves.easeOutBack,
                          )
                          .rotate(
                            begin: i.isEven ? -0.25 : 0.25,
                            delay: delay,
                            duration: 750.ms,
                          );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('See people'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FutureBuilder<int>(
                        future: _reviewCount,
                        builder: (context, s) => FilledButton(
                          onPressed: (s.data ?? 0) == 0
                              ? null
                              : () => Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ReviewScreen(controller: c),
                                  ),
                                ),
                          child: Text(
                            s.data == null
                                ? 'Review faces'
                                : 'Review ${s.data} faces',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(delay: 500.ms).moveY(begin: 20),
          ],
        );
      },
    );
  }
}

/// The photo being scanned, with a box drawing itself around each face it
/// finds; the faces then drop down toward the face stream below.
class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 220,
      child: Center(
        child: AspectRatio(
          aspectRatio: c.previewAspect.clamp(0.5, 2.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                c.preview!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Decode small: the preview is ~220 dp tall, not 1600 px.
                cacheHeight: 480,
              ),
                // Radar sweep while it looks for faces.
                IgnorePointer(
                  child: Transform.scale(
                    scale: 2.2,
                    child:
                        DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: SweepGradient(
                                  colors: [
                                    Colors.transparent,
                                    scheme.primary.withAlpha(0),
                                    scheme.primary.withAlpha(90),
                                    Colors.transparent,
                                  ],
                                  stops: const [0, 0.72, 0.98, 1],
                                ),
                              ),
                            )
                            .animate(onPlay: (a) => a.repeat())
                            .rotate(duration: 1700.ms),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  key: ValueKey(c.previewId),
                  tween: Tween(begin: 0, end: 1),
                  duration: 450.ms,
                  curve: Curves.easeOutCubic,
                  builder: (_, t, _) => CustomPaint(
                    painter: _BoxPainter(c.previewFaces, t, scheme.primary),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, box) {
                    return Stack(
                      children: [
                        for (
                          var i = 0;
                          i < c.previewFaces.length &&
                              i < c.previewThumbs.length;
                          i++
                        )
                          Positioned(
                            left:
                                c.previewFaces[i].center.dx * box.maxWidth - 18,
                            top:
                                c.previewFaces[i].center.dy * box.maxHeight -
                                18,
                            child:
                                ClipOval(
                                      child: Image.memory(
                                        c.previewThumbs[i],
                                        width: 36,
                                        height: 36,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                    .animate(key: ValueKey('${c.previewId}-$i'))
                                    .fadeIn(delay: 380.ms, duration: 120.ms)
                                    .moveY(
                                      delay: 420.ms,
                                      end: box.maxHeight,
                                      duration: 600.ms,
                                      curve: Curves.easeInCubic,
                                    )
                                    .scaleXY(
                                      delay: 420.ms,
                                      end: 1.4,
                                      duration: 600.ms,
                                    )
                                    .fadeOut(delay: 800.ms, duration: 200.ms),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded face boxes whose outline is traced from 0 to [t] of the way round.
class _BoxPainter extends CustomPainter {
  _BoxPainter(this.faces, this.t, this.color);

  final List<Rect> faces;
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final glow = Paint()
      ..color = Colors.white.withAlpha(160)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    for (final f in faces) {
      final r = Rect.fromLTWH(
        f.left * size.width,
        f.top * size.height,
        f.width * size.width,
        f.height * size.height,
      );
      final path = Path()
        ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(10)));
      for (final m in path.computeMetrics()) {
        final part = m.extractPath(0, m.length * t);
        canvas.drawPath(part, glow);
        canvas.drawPath(part, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.t != t || old.faces != faces || old.color != color;
}

/// "1,000 photos scanned!" pill that drops in, sparkles, and leaves.
class _MilestonePill extends StatelessWidget {
  const _MilestonePill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            const ConfettiBurst(count: 16),
            Material(
              elevation: 6,
              color: scheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(30),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.emoji_events, color: scheme.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Text(
                      text,
                      style: TextStyle(
                        color: scheme.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        )
        .animate()
        .slideY(begin: -1.5, duration: 450.ms, curve: Curves.easeOutBack)
        .fadeIn(duration: 200.ms)
        .then(delay: 1600.ms)
        .slideY(end: -1.5, duration: 300.ms, curve: Curves.easeIn)
        .fadeOut(duration: 300.ms);
  }
}
