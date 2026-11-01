import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../data/db.dart';
import 'fast_thumb.dart';
import 'motion.dart';
import 'sections.dart';

/// Round face picture. Shares a [Hero] tag with the person page header so it
/// flies between the two.
class FaceAvatar extends StatelessWidget {
  const FaceAvatar({
    super.key,
    required this.personId,
    required this.thumb,
    required this.radius,
    this.hero = true,
  });

  final int personId;
  final Uint8List? thumb;
  final double radius;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.surfaceContainerHighest,
      backgroundImage: thumb == null ? null : MemoryImage(thumb!),
      child: thumb == null
          ? Icon(Icons.person, size: radius, color: scheme.outline)
          : null,
    );
    return hero ? Hero(tag: 'person-$personId', child: avatar) : avatar;
  }
}

/// A number that rolls to its new value instead of jumping.
class RollingCount extends StatelessWidget {
  const RollingCount({super.key, required this.value, this.style});

  final int value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text('${v.round()}',
          style: style?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}

/// Photo thumbnail loaded straight from the photo library by id.
class AssetThumb extends StatelessWidget {
  const AssetThumb({super.key, required this.id, this.size = 250});

  final String id;
  final int size;

  static final _cache = <String, Future<AssetEntity?>>{};
  static final _ready = <String, AssetEntity>{};

  /// Looks an asset up once and reuses it for every rebuild.
  static Future<AssetEntity?> entity(String id) => _cache.putIfAbsent(id, () async {
        final a = await AssetEntity.fromId(id);
        if (a != null) _ready[id] = a;
        return a;
      });

  /// The asset if it's already been looked up (no waiting, no flicker).
  static AssetEntity? peek(String id) => _ready[id];

  /// Seeds the cache with assets freshly loaded from an album.
  static void remember(Iterable<AssetEntity> assets) {
    for (final a in assets) {
      _cache[a.id] = Future.value(a);
      _ready[a.id] = a;
    }
  }

  /// Drops a cached asset (deleted, moved or changed).
  static void forget(String id) {
    _cache.remove(id);
    _ready.remove(id);
  }

  @override
  Widget build(BuildContext context) {
    final px = FastThumb.step(size.toDouble());
    return Image(
      image: FastThumb(id, px, cover: true),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // Already in memory: show at once; otherwise a quick fade.
      frameBuilder: (context, child, frame, sync) => sync
          ? child
          : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: 160.ms, child: child),
      errorBuilder: (context, _, _) => const Skeleton(radius: 0),
    );
  }
}

/// Floating face bubbles for empty screens.
class EmptyIllustration extends StatelessWidget {
  const EmptyIllustration({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbles = [
      (const Offset(-62, -18), 30.0, scheme.primaryContainer, 0),
      (const Offset(58, -30), 24.0, scheme.tertiaryContainer, 400),
      (const Offset(0, 22), 40.0, scheme.secondaryContainer, 200),
      (const Offset(-30, 58), 18.0, scheme.tertiaryContainer, 700),
      (const Offset(44, 52), 22.0, scheme.primaryContainer, 900),
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 200,
            height: 170,
            child: Stack(alignment: Alignment.center, children: [
              for (final (offset, r, color, delay) in bubbles)
                Transform.translate(
                  offset: offset,
                  child: CircleAvatar(
                    radius: r,
                    backgroundColor: color,
                    child: Icon(Icons.face_rounded,
                        size: r * 1.1, color: scheme.onPrimaryContainer),
                  )
                      .animate(onPlay: (c) => c.repeat(reverse: true))
                      .moveY(
                          begin: -5,
                          end: 5,
                          delay: delay.ms,
                          duration: 1800.ms,
                          curve: Curves.easeInOut),
                ),
              // A little scene: the big face waves...
              Transform.translate(
                offset: const Offset(34, 0),
                child: const Text('👋', style: TextStyle(fontSize: 26))
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .rotate(
                        begin: -0.06,
                        end: 0.08,
                        alignment: Alignment.bottomCenter,
                        duration: 420.ms,
                        curve: Curves.easeInOut),
              ),
              // ...while a camera in the corner takes a photo now and then.
              Transform.translate(
                offset: const Offset(78, -66),
                child: Stack(alignment: Alignment.center, children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                        color: Colors.white, shape: BoxShape.circle),
                  )
                      .animate(onPlay: (c) => c.repeat())
                      .scaleXY(begin: 0, end: 1.6, delay: 2000.ms, duration: 260.ms)
                      .fadeOut(delay: 2000.ms, duration: 380.ms),
                  Icon(Icons.photo_camera_rounded, size: 26, color: scheme.primary)
                      .animate(onPlay: (c) => c.repeat())
                      .scaleXY(begin: 1, end: 0.85, delay: 1900.ms, duration: 100.ms)
                      .then()
                      .scaleXY(begin: 1, end: 1 / 0.85, duration: 160.ms),
                ]),
              ),
            ]),
          ).animate().fadeIn(duration: 500.ms).scale(
              begin: const Offset(0.8, 0.8), curve: Curves.easeOutBack),
          const SizedBox(height: 24),
          Text(message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge)
              .animate()
              .fadeIn(delay: 200.ms),
          if (action != null) ...[
            const SizedBox(height: 20),
            action!.animate().fadeIn(delay: 350.ms).moveY(begin: 10),
          ],
        ]),
      ),
    );
  }
}

/// Little bursting dots for celebrations.
class ConfettiBurst extends StatelessWidget {
  const ConfettiBurst({super.key, this.count = 28});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = [
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      Colors.amber,
      Colors.pinkAccent,
    ];
    final rand = math.Random(7);
    return IgnorePointer(
      child: Stack(alignment: Alignment.center, children: [
        for (var i = 0; i < count; i++)
          Builder(builder: (_) {
            final angle = (i / count) * 2 * math.pi + rand.nextDouble() * 0.4;
            final dist = 90 + rand.nextDouble() * 90;
            final size = 6 + rand.nextDouble() * 6;
            return Container(
              width: size,
              height: size * (i.isEven ? 1 : 2.2),
              decoration: BoxDecoration(
                color: colors[i % colors.length],
                borderRadius: BorderRadius.circular(2),
              ),
            )
                .animate()
                .move(
                    end: Offset(math.cos(angle) * dist, math.sin(angle) * dist),
                    duration: 900.ms,
                    curve: Curves.easeOutCubic)
                .rotate(end: rand.nextDouble() * 2, duration: 900.ms)
                .fadeOut(delay: 500.ms, duration: 500.ms);
          }),
      ]),
    );
  }
}

/// Opens the calendar range picker; returns null if cancelled.
Future<DaySpan?> pickDays(BuildContext context, DaySpan? current) async {
  final now = DateTime.now();
  final range = await showDateRangePicker(
    context: context,
    firstDate: DateTime(2000),
    lastDate: DateTime(now.year, now.month, now.day),
    initialDateRange: current == null
        ? null
        : DateTimeRange(start: current.start, end: current.end),
    helpText: 'Only photos taken between',
    saveText: 'Apply',
  );
  return range == null ? null : DaySpan(range.start, range.end);
}

/// "Any date" chip that opens the range picker, with a clear button once set.
class DateChip extends StatelessWidget {
  const DateChip({super.key, required this.value, required this.onChanged});

  final DaySpan? value;
  final ValueChanged<DaySpan?> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Center(
      child: CapsuleChip(
        icon: Icons.calendar_month_rounded,
        label: v == null ? 'Any date' : formatSpan(v),
        selected: v != null,
        onTap: () async {
          final picked = await pickDays(context, v);
          if (picked != null) onChanged(picked);
        },
        onDeleted: v == null ? null : () => onChanged(null),
      ),
    );
  }
}

/// A face circle that slowly cross-fades between a person's best shots.
class LivingAvatar extends StatefulWidget {
  const LivingAvatar({
    super.key,
    required this.personId,
    required this.cover,
    required this.radius,
    required this.loadFaces,
  });

  final int personId;
  final Uint8List? cover;
  final double radius;
  final Future<List<Uint8List>> Function() loadFaces;

  @override
  State<LivingAvatar> createState() => _LivingAvatarState();
}

class _LivingAvatarState extends State<LivingAvatar> {
  List<Uint8List> _faces = const [];
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.loadFaces().then((faces) {
      if (!mounted || faces.length < 2) return;
      _faces = faces;
      // Stagger so the whole grid doesn't change at the same moment.
      final period = Duration(milliseconds: 3500 + math.Random(widget.personId).nextInt(3000));
      _timer = Timer.periodic(period, (_) {
        // Skip while this tab is hidden.
        if (mounted && (_active?.value.enabled ?? true)) {
          setState(() => _i = (_i + 1) % _faces.length);
        }
      });
    });
  }

  ValueListenable<TickerModeData>? _active;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TickerMode.getValuesNotifier(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _faces.isEmpty ? widget.cover : _faces[_i];
    return Hero(
      tag: 'person-${widget.personId}',
      child: AnimatedSwitcher(
        duration: 900.ms,
        child: FaceAvatar(
          key: ValueKey(_i),
          personId: widget.personId,
          thumb: thumb,
          radius: widget.radius,
          hero: false,
        ),
      ),
    );
  }
}
