import 'package:flutter/material.dart';
import 'anim.dart';

import '../platform/device.dart';
import 'glass.dart';
import 'motion.dart';
import 'theme.dart';

/// The app's look, in pieces: rounded cards of Settings-style rows, a bold
/// header above and a small note below, capsule chips and switches, and
/// the top-bar buttons grouped in one glass capsule. Colours are flat: the
/// accent marks what's selected or primary, everything else is neutral.

/// [height] grown as much as the phone's font size setting grows body text.
/// For boxes that must keep a set height (rows that scroll sideways, bars)
/// but hold text, so large text doesn't spill out of them.
double textHeight(BuildContext context, double height) =>
    height * MediaQuery.textScalerOf(context).scale(14) / 14;

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
            if (i > 0) Divider(height: 0.5, thickness: 0.5, indent: Device.desktop ? 50 : 62),
            r,
          ],
        ]);

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (Device.desktop) {
      // A Mac grouped box: solid card, hairline rim, a faint lift.
      return Container(
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Mac.card(context),
          borderRadius: BorderRadius.circular(Mac.cardRadius),
          border: Border.all(color: Mac.hairline(context), width: 0.5),
          boxShadow: dark
              ? null
              : const [BoxShadow(color: Color(0x0A000000), blurRadius: 3, offset: Offset(0, 1))],
        ),
        child: Material(type: MaterialType.transparency, child: child),
      );
    }
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
    if (Device.desktop) {
      // Smaller and quieter on a computer, as above a Mac settings group.
      return Padding(
        padding: EdgeInsets.fromLTRB(4, top * 0.75, 0, 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 30),
          child: Row(children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            if (badge != null) ...[const SizedBox(width: 8), badge!],
            const Spacer(),
            ?trailing,
          ]),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 0, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
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
      padding: Device.desktop ? const EdgeInsets.fromLTRB(12, 6, 12, 0) : const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(text,
          textAlign: align,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: Device.desktop ? TextSize.small : TextSize.caption,
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
    // Mac System Settings uses smaller tiles than the phone.
    final size = Device.desktop ? 26.0 : 32.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Device.desktop ? 7 : 9)),
      child: Icon(icon, size: Device.desktop ? 16 : 19, color: iconColor),
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
    final desk = Device.desktop;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: desk ? 44 : 56),
      child: Padding(
        padding: desk
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 7)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          if (leading != null) ...[leading!, SizedBox(width: desk ? 12 : 14)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: desk ? TextSize.label : TextSize.body,
                      fontWeight: desk ? FontWeight.w500 : null,
                      color: destructive ? scheme.error : null)),
              if (subtitle != null)
                Text(subtitle!,
                    style: TextStyle(
                        fontSize: desk ? TextSize.small : TextSize.caption, height: 1.3, color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (chevron) ...[
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: desk ? 18 : null, color: scheme.onSurfaceVariant.withAlpha(140)),
          ],
        ]),
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: enabled ? onTap : null,
        mouseCursor: enabled && onTap != null ? SystemMouseCursors.click : null,
        child: row,
      ),
    );
  }
}

/// Top-bar buttons grouped in one glass capsule.
class ToolbarCapsule extends StatelessWidget {
  const ToolbarCapsule({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (Device.desktop) {
      // A Mac toolbar group: borderless buttons that tint under the mouse.
      return Center(child: Row(mainAxisSize: MainAxisSize.min, children: children));
    }
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
    this.menu = false,
    this.onTap,
    this.onLongPress,
    this.onDeleted,
  });

  final String label;
  final IconData? icon;
  final int? count;
  final bool selected;

  /// Opens a list to pick from: shows a small arrow.
  final bool menu;

  /// An action rather than a choice ("New group").
  final bool outlined;
  final VoidCallback? onTap, onLongPress, onDeleted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : outlined ? scheme.onSurfaceVariant : scheme.onSurface;
    final desk = Device.desktop;
    return Semantics(
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        scale: 0.94,
        child: AnimatedContainer(
          duration: 220.ms,
          height: textHeight(context, desk ? 30 : 36),
          padding: EdgeInsets.only(
              left: icon == null ? (desk ? 12 : 14) : (desk ? 9 : 11),
              right: onDeleted != null ? 6 : menu ? 8 : (desk ? 12 : 14)),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : outlined ? Colors.transparent : capsuleFill(context),
            borderRadius: BorderRadius.circular(18),
            border: outlined ? Border.all(color: capsuleFill(context), width: 1.5) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: desk ? 15 : 17, color: fg), SizedBox(width: desk ? 5 : 6)],
            Text(label,
                style: TextStyle(
                    fontSize: desk ? TextSize.caption : TextSize.label,
                    fontWeight: desk ? FontWeight.w500 : FontWeight.w600,
                    color: fg)),
            if (count != null)
              Text('  $count', style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w500, color: fg.withAlpha(170))),
            if (menu)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(Icons.expand_more_rounded, size: 18, color: fg.withAlpha(180)),
              ),
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
    // On a computer: a Mac segmented control, shorter and less rounded,
    // with a thumb that glides rather than bounces.
    final desk = Device.desktop;
    final height = desk ? this.height.clamp(26.0, 30.0) : this.height;
    final outer = desk ? 8.0 : height / 2;
    return Container(
      height: height,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(outer)),
      child: Stack(children: [
        AnimatedAlign(
          alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
          duration: desk ? 220.ms : 420.ms,
          curve: desk ? Curves.easeOutCubic : Curves.easeOutBack,
          child: FractionallySizedBox(
            widthFactor: 1 / n,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF636366) : Colors.white,
                borderRadius: BorderRadius.circular(outer - 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(desk ? 26 : 30),
                    blurRadius: desk ? 3 : 8,
                    offset: Offset(0, desk ? 1 : 3),
                  ),
                ],
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
                        fontSize: desk ? TextSize.caption : TextSize.callout,
                        fontWeight: v == value ? FontWeight.w600 : FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(text: label),
                        if (count != null)
                          TextSpan(
                            text: '  $count',
                            style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
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

/// A Mac-style pop-up button for filters on a computer: an icon, what it's
/// set to and a small arrow, in a bordered rounded box. Tinted with the
/// accent when it's filtering ([active]), with an × to clear it.
class PopupButton extends StatefulWidget {
  const PopupButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.onClear,
    this.tooltip,
  });

  final IconData icon;
  final String label;

  /// Opens its choices; the context is the button's, for [showMenuBelow].
  final ValueChanged<BuildContext> onTap;
  final bool active;
  final VoidCallback? onClear;
  final String? tooltip;

  @override
  State<PopupButton> createState() => _PopupButtonState();
}

class _PopupButtonState extends State<PopupButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = widget;
    final on = w.active;
    final fg = on ? scheme.primary : scheme.onSurface;
    final button = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => w.onTap(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 30,
          padding: EdgeInsets.only(left: 10, right: on && w.onClear != null ? 4 : 8),
          decoration: BoxDecoration(
            color: on
                ? scheme.primary.withValues(alpha: _hover ? 0.18 : 0.12)
                : _hover
                    ? Mac.hover(context)
                    : Mac.card(context),
            borderRadius: BorderRadius.circular(Mac.controlRadius),
            border: Border.all(
              color: on ? scheme.primary.withValues(alpha: 0.45) : Mac.hairline(context),
              width: on ? 1 : 0.8,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(w.icon, size: 15, color: on ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(w.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w500, color: fg)),
            ),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, size: 17, color: fg.withValues(alpha: 0.7)),
            if (on && w.onClear != null)
              InkResponse(
                onTap: w.onClear,
                radius: 12,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close_rounded, size: 14, color: scheme.primary),
                ),
              ),
          ]),
        ),
      ),
    );
    return w.tooltip == null ? button : Tooltip(message: w.tooltip!, child: button);
  }
}

/// Opens a menu just below [button] (a [PopupButton]'s context).
Future<T?> showMenuBelow<T>(BuildContext button, List<PopupMenuEntry<T>> items) {
  final box = button.findRenderObject() as RenderBox;
  final overlay = Overlay.of(button).context.findRenderObject() as RenderBox;
  final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
  return showMenu<T>(
    context: button,
    position: RelativeRect.fromRect(topLeft & const Size(1, 1), Offset.zero & overlay.size),
    items: items,
  );
}

/// One choice in a [showMenuBelow] menu: a tick when chosen, the label,
/// and an optional count on the right.
PopupMenuItem<T> menuChoice<T>(BuildContext context, T value, String label,
    {bool selected = false, int? count, IconData? icon}) {
  final scheme = Theme.of(context).colorScheme;
  return PopupMenuItem<T>(
    value: value,
    height: 34,
    child: Row(children: [
      SizedBox(
        width: 22,
        child: selected ? Icon(Icons.check_rounded, size: 16, color: scheme.primary) : null,
      ),
      if (icon != null) ...[Icon(icon, size: 16, color: scheme.onSurfaceVariant), const SizedBox(width: 8)],
      Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
      if (count != null) ...[
        const SizedBox(width: 16),
        Text('$count', style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
      ],
    ]),
  );
}
