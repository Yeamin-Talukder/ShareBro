import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

// Every screen imports flutter_animate through this file, so one `.animate()`
// (below) decides for the whole app whether entrances play.
export 'package:flutter_animate/flutter_animate.dart' hide AnimateWidgetExtensions;

/// Android's "Remove animations" is on.
bool get reduceMotion =>
    WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

/// flutter_animate's `.animate()`, but with "Remove animations" on it shows
/// each effect's end state at once: no entrances, no bounces, no loops.
/// State-driven effects (`target:`) jump to their target instead of easing.
extension CalmAnimate on Widget {
  Animate animate({
    Key? key,
    List<Effect>? effects,
    AnimateCallback? onInit,
    AnimateCallback? onPlay,
    AnimateCallback? onComplete,
    bool? autoPlay,
    Duration? delay,
    AnimationController? controller,
    Adapter? adapter,
    double? target,
    double? value,
  }) {
    // A caller driving it with its own controller or adapter decides itself.
    final calm = reduceMotion && controller == null && adapter == null;
    return Animate(
      key: key,
      effects: effects,
      onInit: onInit,
      onPlay: calm ? null : onPlay,
      // Jumping to the end "completes" while the widget is still being
      // built, so run the callback once that build is done.
      onComplete: calm && onComplete != null
          ? (c) => WidgetsBinding.instance.addPostFrameCallback((_) => onComplete(c))
          : onComplete,
      autoPlay: calm ? false : autoPlay,
      delay: calm ? Duration.zero : delay,
      controller: controller,
      adapter: adapter,
      target: target,
      value: calm ? (target ?? 1) : value,
      child: this,
    );
  }
}
