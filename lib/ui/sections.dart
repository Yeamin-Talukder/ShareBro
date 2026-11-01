import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'glass.dart';
import 'motion.dart';

/// The app's look, in pieces: rounded cards of Settings-style rows, a bold
/// header above and a small note below, capsule chips and switches, and
/// the top-bar buttons grouped in one glass capsule. Colours are flat: the
/// accent marks what's selected or primary, everything else is neutral.

/// The quiet fill behind chips, switches and square buttons.
Color capsuleFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0x3D767680) : const Color(0x1F767680);

/// A rounded card that groups rows or a single piece of content.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.padding = EdgeInsets.zero});

  /// Rows separated by inset hairlines.
  SectionCard.rows({super.key, required List<Widget> rows, this.padding = EdgeInsets.zero})
      : child = Column(children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) const Divider(height: 0.5, thickness: 0.5, indent: 62),
            r,
          ],
        ]);

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: dark ? const Color(0xC71C1C1F) : const Color(0xD9FFFFFF),
        borderRadius: BorderRadius.circular(26),
        border: dark ? Border.all(color: Colors.white.withAlpha(14)) : null,
      ),
      child: child,
    );
  }
}

/// "Nearby", "Options": a bold section title with optional extras.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.badge, this.trailing, this.top = 26});

  final String title;
  final Widget? badge, trailing;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 0, 8),
      child: SizedBox(
        height: 36,
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (badge != null) ...[const SizedBox(width: 8), badge!],
          const Spacer(),
          ?trailing,
        ]),
      ),
    );
  }
}

/// The small explanatory text under a section.
class SectionFooter extends StatelessWidget {
  const SectionFooter(this.text, {super.key, this.align = TextAlign.start});

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(text,
          textAlign: align,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 13,
                height: 1.4,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )),
    );
  }
}

/// A coloured rounded square with a white symbol, as in Settings.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color, this.iconColor = Colors.white});

  final IconData icon;
  final Color color, iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
      child: Icon(icon, size: 19, color: iconColor),
    );
  }
}

/// One row in a [SectionCard]: icon tile, title and subtitle, and a trailing
/// control or chevron.
class SectionRow extends StatelessWidget {
  const SectionRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.chevron = false,
    this.destructive = false,
  });

  final Widget? leading, trailing;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool enabled, chevron, destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 14)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16.5, color: destructive ? scheme.error : null)),
              if (subtitle != null)
                Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (chevron) ...[
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant.withAlpha(140)),
          ],
        ]),
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(onTap: enabled ? onTap : null, child: row),
    );
  }
}

/// Top-bar buttons grouped in one glass capsule.
class ToolbarCapsule extends StatelessWidget {
  const ToolbarCapsule({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Glass(
        radius: 24,
        shadow: false,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A capsule chip: neutral, or filled with the accent when [selected].
class CapsuleChip extends StatelessWidget {
  const CapsuleChip({
    super.key,
    required this.label,
    this.icon,
    this.count,
    this.selected = false,
    this.outlined = false,
    this.onTap,
    this.onLongPress,
    this.onDeleted,
  });

  final String label;
  final IconData? icon;
  final int? count;
  final bool selected;

  /// An action rather than a choice ("New group").
  final bool outlined;
  final VoidCallback? onTap, onLongPress, onDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : outlined ? scheme.onSurfaceVariant : scheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.94,
        child: AnimatedContainer(
          duration: 220.ms,
          height: 36,
          padding: EdgeInsets.only(left: icon == null ? 14 : 11, right: onDeleted == null ? 14 : 6),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : outlined ? Colors.transparent : capsuleFill(context),
            borderRadius: BorderRadius.circular(18),
            border: outlined ? Border.all(color: capsuleFill(context), width: 1.5) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 17, color: fg), const SizedBox(width: 6)],
            Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
            if (count != null)
              Text('  $count', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: fg.withAlpha(170))),
            if (onDeleted != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDeleted,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.close_rounded, size: 18, color: fg),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// A capsule switch between a few choices, with a thumb that slides to the
/// chosen one.
class CapsuleSwitch<T> extends StatelessWidget {
  const CapsuleSwitch({super.key, required this.value, required this.options, required this.onChanged, this.height = 40});

  final T value;

  /// Each choice, its label and an optional count shown beside it.
  final List<(T, String, int?)> options;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final n = options.length;
    final index = options.indexWhere((o) => o.$1 == value).clamp(0, n - 1);
    return Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(height / 2)),
      child: Stack(children: [
        AnimatedAlign(
          alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
          duration: 420.ms,
          curve: Curves.easeOutBack,
          child: FractionallySizedBox(
            widthFactor: 1 / n,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF636366) : Colors.white,
                borderRadius: BorderRadius.circular(height / 2 - 2),
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 8, offset: const Offset(0, 3))],
              ),
            ),
          ),
        ),
        Row(children: [
          for (final (v, label, count) in options)
            Expanded(
              child: Semantics(
                button: true,
                selected: v == value,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (v != value) {
                      Haptics.tick();
                      onChanged(v);
                    }
                  },
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: 200.ms,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: v == value ? FontWeight.w600 : FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: label),
                        if (count != null)
                          TextSpan(
                            text: '  $count',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
                          ),
                      ])),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
