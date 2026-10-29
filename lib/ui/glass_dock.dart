import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'glass.dart';

/// Height of the floating dock plus its margin, for content to clear it.
const dockClearance = 96.0;

/// Screens that need the bottom edge for themselves (a selection bar)
/// tuck the dock away while they hold it.
class DockVisibility {
  static final hidden = ValueNotifier<bool>(false);
  static final Set<Object> _holders = {};

  static void hide(Object holder) {
    _holders.add(holder);
    hidden.value = true;
  }

  static void show(Object holder) {
    _holders.remove(holder);
    hidden.value = _holders.isNotEmpty;
  }
}

class DockItem {
  const DockItem(this.icon, this.selectedIcon, this.label);

  final IconData icon, selectedIcon;
  final String label;
}

/// Floating glass tab bar. The selected tab sits on a tinted "drop" that
/// slides to the new tab and stretches while it travels, like liquid.
class GlassDock extends StatefulWidget {
  const GlassDock({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
  });

  final List<DockItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  State<GlassDock> createState() => _GlassDockState();
}

class _GlassDockState extends State<GlassDock> with SingleTickerProviderStateMixin {
  late final AnimationController _move =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  late double _from = widget.index.toDouble();
  late double _to = widget.index.toDouble();

  @override
  void didUpdateWidget(covariant GlassDock old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _from = _position;
      _to = widget.index.toDouble();
      if (MediaQuery.disableAnimationsOf(context)) {
        _move.value = 1;
      } else {
        _move.forward(from: 0);
      }
    }
  }

  double get _position =>
      _from + (_to - _from) * Curves.easeOutBack.transform(_move.value.clamp(0, 1));

  @override
  void dispose() {
    _move.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 12 + bottom),
      child: SizedBox(
        height: 68,
        child: Glass(
          radius: 34,
          padding: const EdgeInsets.all(6),
          child: LayoutBuilder(builder: (context, box) {
            final slot = box.maxWidth / widget.items.length;
            return AnimatedBuilder(
              animation: _move,
              builder: (context, _) {
                // Stretch most at mid-flight, settle back to a pill at rest.
                final travel = (_to - _from).abs();
                final stretch = travel == 0
                    ? 0.0
                    : (1 - (2 * _move.value - 1).abs()) * 0.5 * travel;
                final width = slot * (1 + stretch);
                final left = _position * slot - (width - slot) / 2;
                return Stack(children: [
                  Positioned(
                    left: left.clamp(0, box.maxWidth - width),
                    top: 0,
                    bottom: 0,
                    width: width,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary.withAlpha(46),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: scheme.primary.withAlpha(60)),
                      ),
                    ),
                  ),
                  Row(children: [
                    for (var i = 0; i < widget.items.length; i++)
                      Expanded(
                        child: Semantics(
                          selected: i == widget.index,
                          button: true,
                          label: widget.items[i].label,
                          child: InkResponse(
                            onTap: () => widget.onSelect(i),
                            radius: 36,
                            child: _Tab(item: widget.items[i], selected: i == widget.index),
                          ),
                        ),
                      ),
                  ]),
                ]);
              },
            );
          }),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.selected});

  final DockItem item;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Monochrome labels on glass; brand colour only on the selected tab.
    final color = selected ? scheme.primary : scheme.onSurface.withAlpha(190);
    final icon = Icon(selected ? item.selectedIcon : item.icon, color: color, size: 24);
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      selected
          ? icon
              .animate(key: ValueKey('on-${item.label}'))
              .scaleXY(begin: 0.7, duration: 450.ms, curve: Curves.elasticOut)
          : icon,
      const SizedBox(height: 2),
      Text(item.label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          )),
    ]);
  }
}
