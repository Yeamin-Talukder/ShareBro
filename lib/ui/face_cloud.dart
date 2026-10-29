import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import 'widgets.dart';

/// Everyone as floating bubbles, bigger for people in more photos.
class FaceCloud extends StatelessWidget {
  const FaceCloud({super.key, required this.people, required this.onOpen});

  final List<PersonSummary> people;
  final ValueChanged<PersonSummary> onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      final placed = _pack(width);
      final height = placed.isEmpty
          ? 0.0
          : placed.map((p) => p.centre.dy + p.radius).reduce(math.max) + 24;
      return SizedBox(
        width: width,
        height: height,
        child: Stack(children: [
          for (final (i, p) in placed.indexed)
            Positioned(
              left: p.centre.dx - p.radius,
              top: p.centre.dy - p.radius,
              child: GestureDetector(
                onTap: () => onOpen(p.person),
                child: Tooltip(
                  message: '${p.person.displayName} · ${p.person.photoCount} photos',
                  child: FaceAvatar(
                    personId: p.person.id,
                    thumb: p.person.coverThumb,
                    radius: p.radius - 3,
                  ),
                ),
              )
                  .animate()
                  .scaleXY(
                      begin: 0,
                      delay: (30 * i.clamp(0, 30)).ms,
                      duration: 600.ms,
                      curve: Curves.elasticOut)
                  // Then drift gently forever, each at its own pace.
                  .animate(onPlay: (c) => c.repeat(reverse: true))
                  .move(
                      begin: Offset(0, -4 - (i % 3).toDouble()),
                      end: Offset((i.isEven ? 3 : -3).toDouble(), 4 + (i % 3).toDouble()),
                      duration: (2200 + 300 * (i % 5)).ms,
                      curve: Curves.easeInOut),
            ),
        ]),
      );
    });
  }

  /// Places the biggest bubbles near the top centre, then fits each next one
  /// along a spiral at the first spot where it doesn't overlap.
  List<_Bubble> _pack(double width) {
    if (people.isEmpty) return const [];
    final maxCount = people.map((p) => p.photoCount).reduce(math.max).toDouble();
    final sorted = [...people]..sort((a, b) => b.photoCount.compareTo(a.photoCount));
    final placed = <_Bubble>[];
    final centre = Offset(width / 2, 90);
    for (final person in sorted) {
      final r = 26 + 40 * math.sqrt(person.photoCount / math.max(maxCount, 1));
      var angle = 0.0;
      var dist = 0.0;
      // Bounded so a very narrow screen can never hang the layout.
      for (var step = 0; step < 8000; step++) {
        final c = centre + Offset(math.cos(angle) * dist, math.sin(angle) * dist * 0.85 + dist * 0.6);
        final fits = c.dx - r >= 4 &&
            c.dx + r <= width - 4 &&
            c.dy - r >= 4 &&
            placed.every((b) => (b.centre - c).distance >= b.radius + r + 6);
        if (fits) {
          placed.add(_Bubble(person, c, r));
          break;
        }
        angle += 0.35;
        dist += 1.6;
      }
      if (placed.isEmpty || placed.last.person != person) {
        final bottom = placed.isEmpty ? 0.0 : placed.map((b) => b.centre.dy + b.radius).reduce(math.max);
        placed.add(_Bubble(person, Offset(width / 2, bottom + r + 6), r));
      }
    }
    return placed;
  }
}

class _Bubble {
  _Bubble(this.person, this.centre, this.radius);

  final PersonSummary person;
  final Offset centre;
  final double radius;
}
