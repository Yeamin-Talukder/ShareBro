import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Drag-box selection over a scrolling grid, as in Explorer or Finder: press
/// the mouse (or the touchpad) and drag to draw a box; every tile it touches
/// is selected. Near the top or bottom edge the grid scrolls on its own.
/// Touch screens keep their own long-press selection, so only a mouse or a
/// touchpad draws the box.
class MarqueeSelect extends StatefulWidget {
  const MarqueeSelect({
    super.key,
    required this.scroll,
    required this.hitTest,
    required this.onStart,
    required this.onUpdate,
    required this.child,
    this.onEmptyClick,
    this.enabled = true,
  });

  /// The grid's scroll position (tiles move under the box as it scrolls).
  final ScrollController scroll;

  /// The tiles (by index) inside [content], a box in the scrolled content's
  /// coordinates: x as in this widget, y from the top of the scroll content.
  final Set<int> Function(Rect content) hitTest;

  /// A box starts. [adding]: Ctrl or Shift is held, so the box adds to the
  /// selection rather than replacing it.
  final void Function(bool adding) onStart;

  /// The tiles inside the box now.
  final ValueChanged<Set<int>> onUpdate;

  /// A plain click that hit no tile (clears the selection, like Explorer).
  final VoidCallback? onEmptyClick;

  final bool enabled;
  final Widget child;

  @override
  State<MarqueeSelect> createState() => _MarqueeSelectState();
}

class _MarqueeSelectState extends State<MarqueeSelect> {
  /// Moving further than this turns a press into a box.
  static const _threshold = 5.0;

  /// The edge band that scrolls the grid while dragging, and the fastest
  /// speed (pixels a frame) right at the edge.
  static const _edge = 48.0;
  static const _maxSpeed = 22.0;

  int? _pointer;
  Offset _startContent = Offset.zero;
  Offset _startLocal = Offset.zero;
  Offset _now = Offset.zero;
  bool _active = false;
  Timer? _autoScroll;
  Size _size = Size.zero;

  double get _offset => widget.scroll.hasClients ? widget.scroll.offset : 0;

  @override
  void dispose() {
    _autoScroll?.cancel();
    super.dispose();
  }

  bool _isPointerDevice(PointerDownEvent e) =>
      e.kind == PointerDeviceKind.mouse || e.kind == PointerDeviceKind.trackpad;

  void _down(PointerDownEvent e) {
    if (!widget.enabled || !_isPointerDevice(e) || e.buttons != kPrimaryButton || _pointer != null) return;
    // Leave the scroll bar at the right edge to itself.
    if (e.localPosition.dx > _size.width - 16) return;
    _pointer = e.pointer;
    _startLocal = e.localPosition;
    _startContent = e.localPosition + Offset(0, _offset);
    _now = e.localPosition;
    _active = false;
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    _now = e.localPosition;
    if (!_active) {
      if ((_now - _startLocal).distance < _threshold) return;
      final keys = HardwareKeyboard.instance;
      _active = true;
      widget.onStart(keys.isControlPressed || keys.isShiftPressed || keys.isMetaPressed);
      _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) => _scrollTick());
    }
    _report();
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    final wasActive = _active;
    _pointer = null;
    _autoScroll?.cancel();
    _autoScroll = null;
    if (wasActive) {
      setState(() => _active = false);
      return;
    }
    // A plain click on empty space (not on a tile) clears the selection.
    if (e is PointerUpEvent) {
      final keys = HardwareKeyboard.instance;
      final p = _startContent;
      final onTile = widget.hitTest(Rect.fromLTWH(p.dx, p.dy, 0.5, 0.5)).isNotEmpty;
      if (!onTile && !keys.isControlPressed && !keys.isShiftPressed) widget.onEmptyClick?.call();
    }
  }

  Rect get _box => Rect.fromPoints(_startContent, _now + Offset(0, _offset));

  void _report() {
    widget.onUpdate(widget.hitTest(_box));
    setState(() {});
  }

  /// Near the top or bottom edge: scroll that way, faster the closer the
  /// pointer is to the edge, and grow the box with it.
  void _scrollTick() {
    if (!_active || !widget.scroll.hasClients) return;
    final y = _now.dy;
    double speed = 0;
    if (y < _edge) speed = -_maxSpeed * (1 - (y / _edge).clamp(0.0, 1.0));
    if (y > _size.height - _edge) speed = _maxSpeed * ((y - (_size.height - _edge)) / _edge).clamp(0.0, 1.0);
    if (speed == 0) return;
    final p = widget.scroll.position;
    final to = (p.pixels + speed).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (to == p.pixels) return;
    widget.scroll.jumpTo(to);
    _report();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      _size = box.biggest;
      final local = _box.shift(Offset(0, -_offset));
      return Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Stack(children: [
          widget.child,
          if (_active)
            Positioned.fromRect(
              rect: Rect.fromLTRB(
                math.max(0, local.left),
                local.top,
                math.min(_size.width, local.right),
                local.bottom,
              ),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    border: Border.all(color: scheme.primary.withValues(alpha: 0.75)),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }
}
