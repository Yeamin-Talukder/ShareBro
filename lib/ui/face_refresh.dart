import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'motion.dart';

/// Pull-to-refresh with a little face that stretches as you pull down and
/// spins while refreshing. Works with the normal Android scroll physics.
class FaceRefresh extends StatefulWidget {
  const FaceRefresh({super.key, required this.onRefresh, required this.child});

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<FaceRefresh> createState() => _FaceRefreshState();
}

class _FaceRefreshState extends State<FaceRefresh> with TickerProviderStateMixin {
  static const _trigger = 90.0;
  static const _rest = 64.0;
  double _pull = 0;
  bool _refreshing = false;
  bool _armed = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: 300.ms)
    ..addListener(() => setState(() => _pull =
        _backFrom + (_backTo - _backFrom) * Curves.easeOut.transform(_back.value)));
  double _backFrom = 0, _backTo = 0;
  late final AnimationController _spin = AnimationController(vsync: this, duration: 900.ms);

  @override
  void dispose() {
    _back.dispose();
    _spin.dispose();
    super.dispose();
  }

  void _animateTo(double v) {
    _backFrom = _pull;
    _backTo = v;
    _back.forward(from: 0);
  }

  bool _onScroll(ScrollNotification n) {
    if (_refreshing || n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification && n.overscroll < 0 && n.dragDetails != null) {
      _back.stop();
      setState(() => _pull = (_pull - n.overscroll * 0.5).clamp(0, 160));
      if (!_armed && _pull >= _trigger) {
        _armed = true;
        Haptics.tick();
      }
    } else if (n is ScrollUpdateNotification && _pull > 0 && n.dragDetails != null) {
      setState(() => _pull = (_pull - (n.scrollDelta ?? 0)).clamp(0, 160));
    }
    return false;
  }

  Future<void> _release() async {
    _armed = false;
    if (_pull < _trigger) {
      _animateTo(0);
      return;
    }
    setState(() => _refreshing = true);
    _animateTo(_rest);
    _spin.repeat();
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        _spin.stop();
        setState(() => _refreshing = false);
        Haptics.success();
        _animateTo(0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stretch = 1 + (_pull / 220).clamp(0.0, 0.5);
    final ready = _pull >= _trigger || _refreshing;
    return Listener(
      onPointerUp: (_) {
        if (_pull > 0 && !_refreshing) _release();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(children: [
          Transform.translate(offset: Offset(0, _pull * 0.6), child: widget.child),
          if (_pull > 0)
            Positioned(
              top: _pull * 0.6 - 52,
              left: 0,
              right: 0,
              child: Center(
                child: RotationTransition(
                  turns: _spin,
                  child: Transform.scale(
                    scaleX: 1 / stretch,
                    scaleY: stretch,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: ready ? scheme.primary : scheme.primaryContainer,
                        shape: BoxShape.circle,
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                      ),
                      child: Icon(
                        _refreshing ? Icons.face_retouching_natural : Icons.face_rounded,
                        color: ready ? scheme.onPrimary : scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
