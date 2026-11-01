import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/places.dart';

/// Plays a [JourneyPlan]: play, pause, scrub, and the camera. The camera
/// follows the plan until a finger moves the map; then it stays where it's
/// put until [refollow] glides it back.
mixin JourneyClock<T extends StatefulWidget> on State<T>, TickerProvider {
  JourneyPlan? get plan;

  /// Seconds into the journey.
  double time = 0;
  bool playing = false;
  bool follow = true;

  /// Where the camera was left by hand.
  CameraFrame? manual;

  CameraFrame? _blendFrom;
  double _blend = 1;
  int _arrived = 0;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// Called after every frame of play (the real map moves its camera here).
  void onFrame() {}

  void disposeClock() => _ticker.dispose();

  void _run() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final p = plan;
    if (p == null) return;
    setState(() {
      if (playing) {
        time = math.min(p.duration, time + dt);
        final a = p.at(time).arrived;
        if (a != _arrived) {
          _arrived = a;
          HapticFeedback.selectionClick();
        }
        if (time >= p.duration) playing = false;
      }
      if (_blend < 1) _blend = math.min(1, _blend + dt / 0.7);
      if (!playing && _blend >= 1) _ticker.stop();
    });
    onFrame();
  }

  bool get finished => plan != null && time >= plan!.duration;

  void play() {
    if (finished) {
      time = 0;
      _arrived = 0;
    }
    setState(() => playing = true);
    _run();
  }

  void pause() => setState(() => playing = false);

  /// Jumps to [fraction] (0..1) of the journey.
  void seek(double fraction) {
    final p = plan;
    if (p == null) return;
    setState(() {
      playing = false;
      time = fraction * p.duration;
      _arrived = p.at(time).arrived;
    });
    onFrame();
  }

  /// A finger moved the map: stop following, start from [current].
  void takeOver(CameraFrame current) {
    if (!follow) return;
    setState(() {
      follow = false;
      manual = current;
    });
  }

  /// Glides from wherever the map was left back onto the journey.
  void refollow(CameraFrame from) {
    setState(() {
      _blendFrom = from;
      _blend = 0;
      follow = true;
    });
    _run();
  }

  /// The camera for [m]: the plan's, the hand-placed one, or between.
  CameraFrame cameraFor(JourneyMoment m) {
    if (!follow) return manual ?? m.camera;
    final from = _blendFrom;
    if (_blend < 1 && from != null) {
      return CameraFrame.lerp(from, m.camera, Curves.easeInOutCubic.transform(_blend));
    }
    return m.camera;
  }
}

/// Latitude/longitude onto a flat plane (Web Mercator), fitted so every
/// place fills [clear] of a viewport of [size]. At camera scale 1 these
/// "base" points are screen points.
class PlaceProjection {
  PlaceProjection(List<Place> places, Size size, this.clear) {
    final xs = [for (final p in places) _x(p.lng)], ys = [for (final p in places) _y(p.lat)];
    var minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    var minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    // A single place (or a tight cluster) still gets a few hundred metres around it.
    const minSpan = 0.00012;
    if (maxX - minX < minSpan) {
      minX -= minSpan / 2;
      maxX += minSpan / 2;
    }
    if (maxY - minY < minSpan) {
      minY -= minSpan / 2;
      maxY += minSpan / 2;
    }
    final w = clear.width, h = clear.height;
    worldPx = math.min(w / (maxX - minX), h / (maxY - minY));
    _left = clear.left + (w - (maxX - minX) * worldPx) / 2 - minX * worldPx;
    _top = clear.top + (h - (maxY - minY) * worldPx) / 2 + maxY * worldPx;
  }

  /// The part of the screen the map shows through (not under the cards).
  final Rect clear;

  /// Width of the whole world, in screen points, at camera scale 1.
  late final double worldPx;
  late final double _left, _top;

  static double _x(double lng) => (lng + 180) / 360;
  static double _y(double lat) {
    final s = math.sin(lat.clamp(-85.0, 85.0) * math.pi / 180);
    return 0.5 * math.log((1 + s) / (1 - s)) / (2 * math.pi) + 0.5;
  }

  Offset of(Place p) => ofLatLng(p.lat, p.lng);
  Offset ofLatLng(double lat, double lng) => Offset(_left + _x(lng) * worldPx, _top - _y(lat) * worldPx);

  ({double lat, double lng}) unproject(Offset base) {
    final x = (base.dx - _left) / worldPx, y = (_top - base.dy) / worldPx;
    final lat = (2 * math.atan(math.exp((y - 0.5) * 2 * math.pi)) - math.pi / 2) * 180 / math.pi;
    return (lat: lat, lng: x * 360 - 180);
  }

  /// Base points per metre around [lat].
  double unitsPerMeter(double lat) => worldPx / (40075016.686 * math.cos(lat * math.pi / 180));

  /// Web map zoom level that shows the base plane at camera [scale].
  double zoomFor(double scale) => math.log(worldPx * scale / 256) / math.ln2;
}

/// Where the camera looks: [center] (a base point) shown at [focal] on
/// screen, magnified [scale] times.
class CameraFrame {
  const CameraFrame(this.center, this.scale);

  final Offset center;
  final double scale;

  Offset toScreen(Offset base, Offset focal) => focal + (base - center) * scale;

  /// Smooth zooms: the scale moves evenly in steps of doubling.
  static CameraFrame lerp(CameraFrame a, CameraFrame b, double t) => CameraFrame(
        Offset.lerp(a.center, b.center, t)!,
        math.exp(math.log(a.scale) + (math.log(b.scale) - math.log(a.scale)) * t),
      );
}

/// What the journey looks like at a moment: the camera, the place last
/// reached, and how far along the leg after it (null while resting).
class JourneyMoment {
  const JourneyMoment(this.camera, this.arrived, this.leg, this.u);

  final CameraFrame camera;
  final int arrived;

  /// The leg being travelled (from stop [leg] to the next) and how far, 0..1.
  final int? leg;
  final double u;

  /// 0..1 along the whole route, given where each stop sits on it.
  double route(List<double> stopAt) =>
      leg == null ? stopAt[arrived] : stopAt[leg!] + (stopAt[leg! + 1] - stopAt[leg!]) * u;
}

// Shot lengths (seconds), like a travel video's edit.
const _intro = 0.7, _dive = 1.3, _rest = 1.6, _travel = 2.6, _outro = 1.4, _end = 0.4;

/// A journey filmed like a travel video: the whole trip first, a dive into
/// the first place, then for every leg a pull back to show where it goes,
/// the dot travelling, and a push in on the place it arrives at. Ends on
/// the whole trip again.
class JourneyPlan {
  JourneyPlan({
    required this.stops,
    required this.closeRadius,
    required this.focal,
    required this.view,
    required this.maxScale,
  }) {
    _close = [for (var i = 0; i < stops.length; i++) _fit(Rect.fromCircle(center: stops[i], radius: closeRadius[i]))];
    _legs = [
      for (var i = 0; i + 1 < stops.length; i++)
        () {
          final f = _fit(Rect.fromPoints(stops[i], stops[i + 1]), pad: 56);
          // Never closer than the two ends' close-ups: it's the wide shot.
          return CameraFrame(f.center, math.min(f.scale, math.min(_close[i].scale, _close[i + 1].scale)));
        }(),
    ];
  }

  /// Stops in base points, in visiting order.
  final List<Offset> stops;

  /// How much ground (base points) around each stop its close-up shows.
  final List<double> closeRadius;

  /// Screen point the camera centres on, and the clear area it frames into.
  final Offset focal;
  final Size view;
  final double maxScale;

  late final List<CameraFrame> _close, _legs;

  /// The whole trip, as first laid out.
  CameraFrame get overview => CameraFrame(focal, 1);

  CameraFrame _fit(Rect r, {double pad = 40}) {
    final w = math.max(r.width, 1e-6), h = math.max(r.height, 1e-6);
    final s = math.min((view.width - 2 * pad) / w, (view.height - 2 * pad) / h);
    return CameraFrame(r.center, s.clamp(1.0, maxScale));
  }

  double get duration =>
      _intro + _dive + stops.length * _rest + (stops.length - 1) * _travel + _outro + _end;

  /// Start time of the rest at stop [i].
  double restStart(int i) => _intro + _dive + i * (_rest + _travel);

  JourneyMoment at(double t) {
    const ease = Curves.easeInOutCubic;
    if (t < _intro) return JourneyMoment(overview, 0, null, 0);
    t -= _intro;
    if (t < _dive) return JourneyMoment(CameraFrame.lerp(overview, _close[0], ease.transform(t / _dive)), 0, null, 0);
    t -= _dive;
    for (var i = 0; i < stops.length; i++) {
      if (t < _rest) {
        // A slow push in while we look around.
        final c = _close[i];
        return JourneyMoment(CameraFrame(c.center, c.scale * (1 + 0.05 * Curves.easeOut.transform(t / _rest))), i, null, 0);
      }
      t -= _rest;
      if (i == stops.length - 1) break;
      if (t < _travel) {
        final u = t / _travel;
        final from = CameraFrame(_close[i].center, _close[i].scale * 1.05);
        final CameraFrame cam;
        if (u < .3) {
          cam = CameraFrame.lerp(from, _legs[i], ease.transform(u / .3));
        } else if (u < .7) {
          cam = _legs[i];
        } else {
          cam = CameraFrame.lerp(_legs[i], _close[i + 1], ease.transform((u - .7) / .3));
        }
        return JourneyMoment(cam, i, i, ease.transform(u));
      }
      t -= _travel;
    }
    final last = stops.length - 1;
    final held = CameraFrame(_close[last].center, _close[last].scale * 1.05);
    return JourneyMoment(CameraFrame.lerp(held, overview, ease.transform((t / _outro).clamp(0.0, 1.0))), last, null, 0);
  }
}
