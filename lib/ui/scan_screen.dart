import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'motion.dart';
import 'review_screen.dart';
import 'aurora.dart';
import 'glass.dart';
import 'sections.dart';
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
        appBar: AppBar(
          leadingWidth: 64,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Center(
              child: GlassIconButton(
                tooltip: 'Back',
                size: 44,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.maybePop(context),
              ),
            ),
          ),
        ),
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
    final faces = c.recentFaces.take(7).toList();
    return CustomScrollView(
      key: const ValueKey('running'),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Scanning', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.7)),
              if (c.albumName != null)
                Row(children: [
                  Icon(Icons.photo_album_rounded, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(c.albumName!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                  ),
                ]),
              const SizedBox(height: 16),
              SectionCard(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  height: 208,
                  child: c.preview == null
                      ? Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                            const SizedBox(height: 12),
                            Text('Getting ready…', style: TextStyle(color: scheme.onSurfaceVariant)),
                          ]),
                        )
                      : _LivePreview(controller: c),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  RollingCount(
                    value: c.done,
                    style: text.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.5,
                      color: scheme.primary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('of ${c.total} photos', style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: c.total == 0 ? 0 : c.done / c.total),
                  duration: 500.ms,
                  curve: Curves.easeOutCubic,
                  builder: (_, v, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: capsuleFill(context)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                child: IntrinsicHeight(
                  child: Row(children: [
                    _Stat(icon: Icons.face_rounded, color: const Color(0xFFFF9F0A), value: '${c.facesFound}', label: 'faces'),
                    const VerticalDivider(width: 0.5, thickness: 0.5, indent: 14, endIndent: 14),
                    _Stat(
                      icon: Icons.group_rounded,
                      color: const Color(0xFF5E5CE6),
                      value: c.peopleSoFar == 0 ? '–' : '≈ ${c.peopleSoFar}',
                      label: 'people so far',
                    ),
                    const VerticalDivider(width: 0.5, thickness: 0.5, indent: 14, endIndent: 14),
                    _Stat(
                      icon: Icons.schedule_rounded,
                      color: const Color(0xFF30B0C7),
                      value: eta == null ? '–' : eta.inMinutes > 0 ? '${eta.inMinutes} min' : '${eta.inSeconds} s',
                      label: 'left',
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                padding: const EdgeInsets.fromLTRB(14, 14, 0, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: Row(children: [
                      const Text('Faces found', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('${c.facesFound}', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  // A conveyor: new faces come in on the left and push the
                  // others along.
                  SizedBox(
                    height: 56,
                    child: ClipRect(
                      child: Stack(children: [
                        for (final (i, thumb) in faces.indexed)
                          AnimatedPositioned(
                            key: ObjectKey(thumb),
                            duration: 450.ms,
                            curve: Curves.easeOutBack,
                            left: i * 60.0,
                            top: 2,
                            child: Container(
                              padding: const EdgeInsets.all(2.5),
                              decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary),
                              child: ClipOval(child: Image.memory(thumb, width: 47, height: 47, fit: BoxFit.cover)),
                            ).animate().scaleXY(begin: 0.2, duration: 500.ms, curve: Curves.elasticOut).fadeIn(duration: 200.ms),
                          ),
                      ]),
                    ),
                  ),
                ]),
              ),
              const Spacer(),
              const SectionFooter('You can lock your phone; scanning keeps going in the background.', align: TextAlign.center),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: capsuleFill(context),
                      foregroundColor: scheme.onSurface,
                    ),
                    onPressed: c.cancel,
                    icon: const Icon(Icons.stop_circle_rounded),
                    label: const Text('Stop scanning'),
                  ),
                ),
              ),
            ]),
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
                  Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primary,
                      boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.primary.withAlpha(36), spreadRadius: 10)],
                    ),
                    child: Icon(Icons.check_rounded, size: 58, color: Theme.of(context).colorScheme.onPrimary),
                  ).animate().scale(begin: Offset.zero, duration: 800.ms, curve: Curves.elasticOut).rotate(begin: -0.25, duration: 600.ms),
                ],
              ),
            ),
            Text(
              'Found ${people.length} people',
              style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.7),
            ).animate().fadeIn(delay: 200.ms).moveY(begin: 12),
            Text(
              'in ${c.done} photos · ${c.facesFound} new faces',
              style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                      return Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: people[i].name == null
                                  ? Theme.of(context).colorScheme.onSurface.withAlpha(60)
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            child: FaceAvatar(
                              personId: people[i].id,
                              thumb: people[i].coverThumb,
                              radius: 31,
                              hero: false,
                            ),
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
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          backgroundColor: capsuleFill(context),
                          foregroundColor: Theme.of(context).colorScheme.onSurface,
                        ),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('See people'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FutureBuilder<int>(
                        future: _reviewCount,
                        builder: (context, s) => FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
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

/// The photo being scanned: a scan line sweeps down it, viewfinder corners
/// snap around each face as the line reaches it, and the faces then drop
/// down toward the conveyor below.
class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    return Center(
      child: AspectRatio(
        aspectRatio: c.previewAspect.clamp(0.5, 2.0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                c.preview!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Decode small: the preview is ~208 dp tall, not 1600 px.
                cacheHeight: 480,
              ),
              TweenAnimationBuilder<double>(
                key: ValueKey(c.previewId),
                tween: Tween(begin: still ? 1 : 0, end: 1),
                duration: 700.ms,
                curve: Curves.easeInOutSine,
                builder: (_, t, _) => CustomPaint(painter: _ScanPainter(c.previewFaces, t, scheme.primary)),
              ),
              LayoutBuilder(
                builder: (context, box) {
                  return Stack(
                    children: [
                      for (var i = 0; i < c.previewFaces.length && i < c.previewThumbs.length; i++)
                        Positioned(
                          left: c.previewFaces[i].center.dx * box.maxWidth - 18,
                          top: c.previewFaces[i].center.dy * box.maxHeight - 18,
                          child: ClipOval(
                            child: Image.memory(c.previewThumbs[i], width: 36, height: 36, fit: BoxFit.cover),
                          )
                              .animate(key: ValueKey('${c.previewId}-$i'))
                              .fadeIn(delay: 620.ms, duration: 120.ms)
                              .moveY(delay: 660.ms, end: box.maxHeight, duration: 600.ms, curve: Curves.easeInCubic)
                              .scaleXY(delay: 660.ms, end: 1.4, duration: 600.ms)
                              .fadeOut(delay: 1040.ms, duration: 200.ms),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The scan line at [t] of the way down (with a faint tint behind it), and
/// viewfinder corners around every face the line has passed.
class _ScanPainter extends CustomPainter {
  _ScanPainter(this.faces, this.t, this.color);

  final List<Rect> faces;
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * t;
    final fade = t < 0.92 ? 1.0 : (1 - (t - 0.92) / 0.08).clamp(0.0, 1.0);
    if (fade > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, y), Paint()..color = color.withValues(alpha: 0.08 * fade));
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..strokeWidth = 2
          ..color = color.withValues(alpha: fade),
      );
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final f in faces) {
      // Snap in (from a little bigger) just after the line passes.
      final a = ((t - f.center.dy) / 0.12).clamp(0.0, 1.0);
      if (a == 0) continue;
      final grow = 1 + 0.6 * (1 - Curves.easeOutBack.transform(a));
      final box = Rect.fromCenter(
        center: Offset(f.center.dx * size.width, f.center.dy * size.height),
        width: f.width * size.width * 1.15 * grow,
        height: f.height * size.height * 1.15 * grow,
      );
      final arm = (box.shortestSide * 0.28).clamp(8.0, 18.0);
      paint.color = color.withValues(alpha: a);
      for (final (corner, dx, dy) in [
        (box.topLeft, 1.0, 1.0),
        (box.topRight, -1.0, 1.0),
        (box.bottomLeft, 1.0, -1.0),
        (box.bottomRight, -1.0, -1.0),
      ]) {
        canvas.drawPath(
          Path()
            ..moveTo(corner.dx, corner.dy + dy * arm)
            ..lineTo(corner.dx, corner.dy)
            ..lineTo(corner.dx + dx * arm, corner.dy),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ScanPainter old) => old.t != t || old.faces != faces || old.color != color;
}

/// One number in the stats card, with a Settings-style icon; it bumps when
/// it changes.
class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.value, required this.label});

  final IconData icon;
  final Color color;
  final String value, label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 17, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(value,
                  maxLines: 1,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()]))
              .animate(key: ValueKey(value))
              .scaleXY(begin: 1.25, alignment: Alignment.centerLeft, duration: 450.ms, curve: Curves.elasticOut),
          Text(label, maxLines: 1, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
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
              color: Colors.black,
              borderRadius: BorderRadius.circular(30),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.celebration_rounded, color: scheme.primary),
                    const SizedBox(width: 10),
                    Text(
                      text,
                      style: const TextStyle(
                        color: Colors.white,
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
