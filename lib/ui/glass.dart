import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'motion.dart';

/// Regular glass for bars, sheets and anything with text; clear glass only
/// for controls floating over photos.
enum GlassKind { regular, clear }

/// High contrast (or no animations) means: drop the see-through material and
/// use a solid surface instead, so text stays crisp.
bool solidSurfaces(BuildContext context) => MediaQuery.highContrastOf(context);

/// Boosts colour saturation a little so content behind glass stays lively.
const _saturate = ColorFilter.matrix(<double>[
  1.32, -0.25, -0.07, 0, 0, //
  -0.08, 1.24, -0.16, 0, 0, //
  -0.08, -0.25, 1.33, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// The glass material for the floating layer: backdrop blur with a light
/// saturation boost, a mostly solid flat fill and a hairline rim. The
/// background is plain, so the fill (not the blur) has to set the glass
/// apart from it; the blur matters only once content slides underneath.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.kind = GlassKind.regular,
    this.radius = 28,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.shadow = true,
    this.shape = BoxShape.rectangle,
    this.fade = 1,
  });

  final Widget child;
  final GlassKind kind;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Colours the glass itself; use only for a primary action.
  final Color? tint;
  final bool shadow;
  final BoxShape shape;

  /// 0..1: fades the glass in. Fade with this, never an [Opacity] around
  /// the glass: a blur inside an opacity layer can drop out and leave the
  /// glass invisible.
  final double fade;

  @override
  Widget build(BuildContext context) {
    if (fade <= 0) return Padding(padding: padding, child: child);
    final dark = Theme.of(context).brightness == Brightness.dark || kind == GlassKind.clear;
    final scheme = Theme.of(context).colorScheme;
    final solid = solidSurfaces(context);
    final circle = shape == BoxShape.circle;
    final borderRadius = circle ? null : BorderRadius.circular(radius);

    final fill = tint != null
        ? tint!.withAlpha(solid ? 255 : 215)
        : solid
            ? scheme.surfaceContainerHighest
            : switch (kind) {
                GlassKind.regular => Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xE6252329)
                    : const Color(0xEBFFFFFF),
                // Over photos: smoky, with the 35% dim Apple suggests.
                GlassKind.clear => const Color(0x59000000),
              };

    // A light rim in the dark, a dark one in the light: a white rim on a
    // near-white page doesn't show.
    final rim = solid ? scheme.outline : (dark ? Colors.white.withAlpha(34) : Colors.black.withAlpha(20));
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        color: fill.withValues(alpha: fill.a * fade),
        shape: shape,
        borderRadius: borderRadius,
        border: Border.all(color: rim.withValues(alpha: rim.a * fade), width: solid ? 1.5 : 1),
      ),
      child: Padding(padding: padding, child: child),
    );

    final blurred = solid
        ? decorated
        : BackdropFilter(
            filter: ImageFilter.compose(
              outer: ImageFilter.blur(
                // Strong enough to read as glass; lighter blurs cost less.
                sigmaX: (kind == GlassKind.regular ? 18 : 10) * fade,
                sigmaY: (kind == GlassKind.regular ? 18 : 10) * fade,
              ),
              inner: _saturate,
            ),
            child: decorated,
          );

    final clipped = circle
        ? ClipOval(child: blurred)
        : ClipRRect(borderRadius: borderRadius!, child: blurred);

    if (!shadow || fade < 1) return clipped;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: shape,
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(dark ? 90 : 28),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: clipped,
    );
  }
}

/// A round 48 dp glass button (meets the 44 pt target guideline) with a
/// quick springy press.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.kind = GlassKind.regular,
    this.size = 48,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final GlassKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = kind == GlassKind.clear ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: Glass(
            kind: kind,
            shape: BoxShape.circle,
            shadow: kind == GlassKind.regular,
            child: Center(
              child: IconTheme(data: IconThemeData(color: color, size: 22), child: icon),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass bar pinned to the top of a scrolling page. It stays invisible at
/// the top of the page and fades in as content scrolls under it (the
/// "scroll edge effect").
class GlassTopBar extends StatelessWidget {
  const GlassTopBar({super.key, required this.visible});

  /// 0 at the top of the page, 1 once content is underneath.
  final double visible;

  @override
  Widget build(BuildContext context) =>
      Glass(radius: 0, shadow: false, fade: visible.clamp(0, 1), child: const SizedBox.expand());
}

/// A top-level page: a large title that scrolls away, and a pinned bar that
/// turns to glass (with the small title) once content slides under it.
class GlassScrollView extends StatefulWidget {
  const GlassScrollView({
    super.key,
    required this.title,
    required this.slivers,
    this.actions = const [],
    this.subtitle,
    this.physics,
  });

  final String title;

  /// A quiet line under the large title ("12 people").
  final String? subtitle;

  /// Pass [NeverScrollableScrollPhysics] when the content takes the
  /// finger itself.
  final ScrollPhysics? physics;
  final List<Widget> actions;
  final List<Widget> slivers;

  @override
  State<GlassScrollView> createState() => _GlassScrollViewState();
}

class _GlassScrollViewState extends State<GlassScrollView> {
  bool _scrolled = false;
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(GlassScrollView old) {
    super.didUpdateWidget(old);
    // Content that takes the finger itself fits on one screen. Bring the
    // page back to the top, or it stays stuck wherever it was scrolled to,
    // with no way to scroll back up.
    final locked = widget.physics is NeverScrollableScrollPhysics;
    if (locked && old.physics is! NeverScrollableScrollPhysics && _scroll.hasClients && _scroll.offset != 0) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final scrolled = n.metrics.pixels > 36;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(controller: _scroll, physics: widget.physics, slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: Colors.transparent,
          toolbarHeight: 60,
          title: AnimatedOpacity(
            opacity: _scrolled ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Text(widget.title),
          ),
          actions: [...widget.actions, const SizedBox(width: 4)],
          flexibleSpace: TweenAnimationBuilder<double>(
            tween: Tween(end: _scrolled ? 1 : 0),
            duration: const Duration(milliseconds: 220),
            builder: (context, fade, _) => Glass(radius: 0, shadow: false, fade: fade, child: const SizedBox.expand()),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: AnimatedOpacity(
              opacity: _scrolled ? 0 : 1,
              duration: const Duration(milliseconds: 160),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.title, style: text.displaySmall),
                if (widget.subtitle != null)
                  Text(widget.subtitle!,
                      style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
          ),
        ),
        ...widget.slivers,
      ]),
    );
  }
}
