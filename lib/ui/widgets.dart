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

/// A stack of three prints that fans open and closes, the front one
/// lifting, for empty screens.
class EmptyIllustration extends StatelessWidget {
  const EmptyIllustration({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 200,
            height: 170,
            child: _PhotoStack(),
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

/// One loop of the fan: open, then closed again.
const _fanCycle = Duration(milliseconds: 3600);

class _PhotoStack extends StatefulWidget {
  const _PhotoStack();

  @override
  State<_PhotoStack> createState() => _PhotoStackState();
}

class _PhotoStackState extends State<_PhotoStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _fanCycle);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still when animations are turned off.
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final coral = scheme.primary;
    final peach = dark ? const Color(0xFF8A4A3C) : const Color(0xFFFFC3B2);
    final sky = dark ? const Color(0xFF3A2A28) : const Color(0xFFFDE3DA);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // 0 closed, 1 fully fanned, eased in and out.
        final v = (1 - math.cos(2 * math.pi * _c.value)) / 2;
        const deg = math.pi / 180;
        return Stack(alignment: Alignment.center, children: [
          Transform.translate(
            offset: Offset(-6 * v, 0),
            child: Transform.rotate(angle: (-6 - 10 * v) * deg, child: _Print(photo: peach, dark: dark)),
          ),
          Transform.translate(
            offset: Offset(6 * v, 0),
            child: Transform.rotate(angle: (6 + 10 * v) * deg, child: _Print(photo: sky, dark: dark)),
          ),
          Transform.translate(
            offset: Offset(0, -10 * v),
            child: _Print(
              photo: sky,
              dark: dark,
              scene: CustomPaint(painter: _ScenePainter(sun: coral, hill: coral, sunDrop: 4 - 7 * v)),
            ),
          ),
        ]);
      },
    );
  }
}

/// A white-bordered print with a photo, plain or with a little scene.
class _Print extends StatelessWidget {
  const _Print({required this.photo, required this.dark, this.scene});

  final Color photo;
  final bool dark;
  final Widget? scene;

  @override
  Widget build(BuildContext context) => Container(
        width: 76,
        height: 92,
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 26),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF252329) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: (dark ? Colors.white : const Color(0xFF1A1820)).withAlpha(30)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: ColoredBox(color: photo, child: scene ?? const SizedBox.expand()),
        ),
      );
}

/// A sun over a hill, the sun bobbing by [sunDrop].
class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.sun, required this.hill, required this.sunDrop});

  final Color sun, hill;
  final double sunDrop;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on the 60 x 58 grid of the design, scaled to fit.
    canvas.scale(size.width / 60, size.height / 58);
    canvas.drawCircle(Offset(42, 18 + sunDrop), 8, Paint()..color = sun);
    canvas.drawPath(
      Path()
        ..moveTo(0, 58)
        ..lineTo(22, 32)
        ..lineTo(36, 46)
        ..lineTo(46, 38)
        ..lineTo(60, 58)
        ..close(),
      Paint()..color = hill,
    );
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.sunDrop != sunDrop || old.sun != sun || old.hill != hill;
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
    _load();
  }

  @override
  void didUpdateWidget(LivingAvatar old) {
    super.didUpdateWidget(old);
    // A new cover means the faces changed (a merge, a new scan, a chosen
    // picture): pick the set again.
    if (old.cover != widget.cover) _load();
  }

  void _load() {
    widget.loadFaces().then((faces) {
      if (!mounted) return;
      _timer?.cancel();
      _timer = null;
      setState(() {
        _faces = faces.length < 2 ? const [] : faces;
        _i = 0;
      });
      if (_faces.isEmpty) return;
      // Stagger so the whole grid doesn't change at the same moment.
      final period = Duration(milliseconds: 4000 + math.Random(widget.personId).nextInt(3000));
      _timer = Timer.periodic(period, (_) {
        // Skip while this tab is hidden, and stay put with motion turned off.
        if (mounted && (_active?.value.enabled ?? true) && !MediaQuery.disableAnimationsOf(context)) {
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
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // The next face settles in from slightly closer while the last one
        // fades out under it, like a slow photo slideshow.
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 1.12, end: 1.0).animate(a), child: child),
        ),
        layoutBuilder: (current, previous) => ClipOval(
          child: Stack(alignment: Alignment.center, children: [...previous, ?current]),
        ),
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
