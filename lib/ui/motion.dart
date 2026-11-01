import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// One place for vibration patterns, so each kind of action always feels
/// the same.
class Haptics {
  /// Moving through choices: tabs, chips, selecting photos.
  static void tick() => HapticFeedback.selectionClick();

  /// Picking something up (long-press drag, start of a selection).
  static void lift() => HapticFeedback.mediumImpact();

  /// Two things joining: a heavy bump then a light settle.
  static Future<void> merge() async {
    await HapticFeedback.heavyImpact();
    await Future<void>.delayed(90.ms);
    await HapticFeedback.lightImpact();
  }

  /// Removing something.
  static void remove() => HapticFeedback.mediumImpact();

  /// Something finished well: two quick light taps.
  static Future<void> success() async {
    await HapticFeedback.lightImpact();
    await Future<void>.delayed(110.ms);
    await HapticFeedback.lightImpact();
  }

  /// Not allowed / missing input.
  static void warn() => HapticFeedback.heavyImpact();
}

/// Grey placeholder with a moving shine, shown while content loads.
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.radius = 12,
    this.circle = false,
  });

  final double? width, height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
    )
        .animate(onPlay: (c) => c.repeat())
        .shimmer(
            duration: 1300.ms,
            color: scheme.surface.withAlpha(150),
            angle: math.pi / 8);
  }
}

/// Placeholder people grid: circles with two text lines.
class PeopleSkeleton extends StatelessWidget {
  const PeopleSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemCount: 12,
      itemBuilder: (_, _) => const Column(children: [
        Skeleton(width: 88, height: 88, circle: true),
        SizedBox(height: 8),
        Skeleton(width: 64, height: 12, radius: 6),
        SizedBox(height: 6),
        Skeleton(width: 44, height: 10, radius: 5),
      ]),
    );
  }
}

/// Placeholder photo grid with a day header.
class PhotosSkeleton extends StatelessWidget {
  const PhotosSkeleton({super.key, this.columns = 4});

  final int columns;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      // Starts where the grid will, below any top bar it runs under.
      padding: EdgeInsets.fromLTRB(2, MediaQuery.paddingOf(context).top + 2, 2, 2),
      children: [
        for (var section = 0; section < 3; section++) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 18, 14, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Skeleton(width: 140, height: 14, radius: 7),
            ),
          ),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: columns,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
            children: List.generate(
                columns * (section == 0 ? 2 : 1), (_) => const Skeleton(radius: 2)),
          ),
        ],
      ],
    );
  }
}

/// Text that types itself in letter by letter, with a few sparkles.
class TypewriterText extends StatelessWidget {
  const TypewriterText(this.text, {super.key, this.style, this.sparkle = true});

  final String text;
  final TextStyle? style;
  final bool sparkle;

  @override
  Widget build(BuildContext context) {
    final perChar = 55.ms;
    final total = perChar * text.length;
    final typed = TweenAnimationBuilder<int>(
      tween: IntTween(begin: 0, end: text.length),
      duration: total,
      builder: (_, n, _) => Text(text.substring(0, n), style: style),
    );
    if (!sparkle) return typed;
    final color = Theme.of(context).colorScheme.tertiary;
    final rand = math.Random(text.hashCode);
    return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      // Reserve the final width so the layout doesn't jump while typing.
      Opacity(opacity: 0, child: Text(text, style: style)),
      typed,
      for (var i = 0; i < 6; i++)
        Positioned(
          left: rand.nextDouble() * 120 - 10,
          top: rand.nextDouble() * 30 - 14,
          child: Icon(Icons.auto_awesome, size: 10 + rand.nextDouble() * 8, color: color)
              .animate(delay: total * (i / 6))
              .scaleXY(begin: 0, end: 1.2, duration: 300.ms, curve: Curves.easeOutBack)
              .then()
              .scaleXY(end: 0, duration: 400.ms)
              .fadeOut(duration: 400.ms),
        ),
    ]);
  }
}

/// Gives anything a quick, springy "pressed" feel: it dips slightly under
/// the finger and bounces back on release. Brief on purpose, since it runs
/// on every tap.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.95});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? 90.ms : 380.ms,
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}
