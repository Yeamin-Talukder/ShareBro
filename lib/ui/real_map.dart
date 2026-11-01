import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/places.dart';
import 'journey_camera.dart';
import 'motion.dart';
import 'places_screen.dart';

// The Places views on a real map: OpenStreetMap tiles, toned down to the
// app's flat look (grey in light mode, inverted in dark). Needs internet for
// the map itself; pins, photos and the route show without it.

const _userAgent = 'com.photoorganizer.photo_organizer';

/// Takes most of the colour out, so photos and the coral route stand out.
const _muted = ColorFilter.matrix(<double>[
  0.62, 0.30, 0.08, 0, 14, //
  0.22, 0.70, 0.08, 0, 14, //
  0.22, 0.30, 0.48, 0, 14, //
  0, 0, 0, 1, 0, //
]);

List<Widget> _baseLayers(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return [
    TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: _userAgent,
      maxNativeZoom: 19,
      tileBuilder: dark
          ? darkModeTileBuilder
          : (context, tile, _) => ColorFiltered(colorFilter: _muted, child: tile),
    ),
  ];
}

Widget _attribution({Alignment alignment = Alignment.bottomLeft}) => _MapCredit(alignment: alignment);

/// The map's credit, which OpenStreetMap's licence asks to keep on the map:
/// shown for a moment when the map opens, then folded into a small (i) that
/// brings it back on a tap.
class _MapCredit extends StatefulWidget {
  const _MapCredit({required this.alignment});

  final Alignment alignment;

  @override
  State<_MapCredit> createState() => _MapCreditState();
}

class _MapCreditState extends State<_MapCredit> {
  bool _open = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _open = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: GestureDetector(
          onTap: () => setState(() => _open = !_open),
          child: AnimatedContainer(
            duration: 250.ms,
            curve: Curves.easeOutCubic,
            height: 26,
            padding: EdgeInsets.symmetric(horizontal: _open ? 10 : 0),
            constraints: const BoxConstraints(minWidth: 26),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: AnimatedSize(
              duration: 250.ms,
              curve: Curves.easeOutCubic,
              child: _open
                  ? Text('© OpenStreetMap contributors',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
                  : Icon(Icons.info_outline_rounded, size: 15, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

LatLng _ll(Place p) => LatLng(p.lat, p.lng);

/// Moves a map smoothly to [center] / [zoom].
class _Flight {
  _Flight(TickerProvider vsync, this.map) : _c = AnimationController(vsync: vsync, duration: 700.ms) {
    _c.addListener(() {
      final k = Curves.easeInOutCubic.transform(_c.value);
      map.move(
        LatLng(_from.latitude + (_to.latitude - _from.latitude) * k,
            _from.longitude + (_to.longitude - _from.longitude) * k),
        _fromZoom + (_toZoom - _fromZoom) * k,
      );
    });
  }

  final MapController map;
  final AnimationController _c;
  LatLng _from = const LatLng(0, 0), _to = const LatLng(0, 0);
  double _fromZoom = 0, _toZoom = 0;

  void to(MapCamera target) {
    _from = map.camera.center;
    _fromZoom = map.camera.zoom;
    _to = target.center;
    _toZoom = target.zoom;
    _c.forward(from: 0);
  }

  void dispose() => _c.dispose();
}

// ---------------------------------------------------------------------------
// Map: photo pins on the real map.

class RealPlacesMap extends StatefulWidget {
  const RealPlacesMap({super.key, required this.places, required this.open});

  final List<Place> places;
  final ValueChanged<Place> open;

  @override
  State<RealPlacesMap> createState() => _RealPlacesMapState();
}

class _RealPlacesMapState extends State<RealPlacesMap> with SingleTickerProviderStateMixin {
  final _map = MapController();
  late final _flight = _Flight(this, _map);

  CameraFit get _all => CameraFit.coordinates(
      coordinates: [for (final p in widget.places) _ll(p)], padding: const EdgeInsets.all(72), maxZoom: 16);

  @override
  void dispose() {
    _flight.dispose();
    super.dispose();
  }

  void _zoomTo(List<Place> members) {
    Haptics.tick();
    _flight.to(CameraFit.coordinates(
      coordinates: [for (final p in members) _ll(p)],
      padding: const EdgeInsets.all(90),
      maxZoom: 18,
    ).fit(_map.camera));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCameraFit: _all,
          backgroundColor: Theme.of(context).colorScheme.surface,
          interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        ),
        children: [
          ..._baseLayers(context),
          _PinLayer(places: widget.places, open: widget.open, zoomTo: _zoomTo),
          _attribution(),
        ],
      ),
      Positioned(
        right: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 40,
        child: FloatingActionButton.small(
          heroTag: null,
          tooltip: 'Show everything',
          onPressed: () {
            Haptics.tick();
            _flight.to(_all.fit(_map.camera));
          },
          child: const Icon(Icons.zoom_out_map_rounded),
        ),
      ),
    ]);
  }
}

/// Pins that merge when they'd overlap at this zoom, worked out again as
/// the map moves.
class _PinLayer extends StatelessWidget {
  const _PinLayer({required this.places, required this.open, required this.zoomTo});

  final List<Place> places;
  final ValueChanged<Place> open;
  final ValueChanged<List<Place>> zoomTo;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final screen = [for (final p in places) camera.latLngToScreenOffset(_ll(p))];
    final order = List.generate(places.length, (i) => i)
      ..sort((a, b) => places[b].photos.length.compareTo(places[a].photos.length));
    final clusters = <({Offset at, List<int> members})>[];
    for (final i in order) {
      final near = clusters.where((c) => (c.at - screen[i]).distance < 64).firstOrNull;
      if (near == null) {
        clusters.add((at: screen[i], members: [i]));
      } else {
        near.members.add(i);
      }
    }
    return MarkerLayer(markers: [
      for (final c in clusters)
        Marker(
          key: ValueKey((List.of(c.members)..sort()).join(',')),
          point: _ll(places[c.members.first]),
          width: pinSize + 40,
          height: pinSize + 8,
          alignment: Alignment.topCenter,
          child: Center(
            child: PhotoPin(
              cover: places[c.members.first].cover,
              count: c.members.fold(0, (n, i) => n + places[i].photos.length),
              label: c.members.length == 1 ? places[c.members.first].name : null,
              onTap: () =>
                  c.members.length == 1 ? open(places[c.members.first]) : zoomTo([for (final i in c.members) places[i]]),
            ),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Journey on the real map, with the same camera as the drawn one.

class RealJourney extends StatefulWidget {
  const RealJourney({super.key, required this.places, required this.trip, required this.open});

  final List<Place> places;
  final bool trip;
  final ValueChanged<Place> open;

  @override
  State<RealJourney> createState() => _RealJourneyState();
}

class _RealJourneyState extends State<RealJourney> with SingleTickerProviderStateMixin, JourneyClock {
  final _map = MapController();
  bool _ready = false;
  Size? _size;
  PlaceProjection? _proj;
  JourneyPlan? _plan;

  /// We're moving the map ourselves (not a finger).
  bool _steering = false;

  @override
  JourneyPlan? get plan => _plan;

  @override
  void dispose() {
    disposeClock();
    super.dispose();
  }

  void _build(Size size, double bottom) {
    if (size == _size) return;
    _size = size;
    final setup = journeySetup(widget.places, size, bottom);
    _proj = setup.proj;
    _plan = setup.plan;
    WidgetsBinding.instance.addPostFrameCallback((_) => onFrame());
  }

  /// The map's centre and zoom showing [cam] (whose centre sits at the
  /// clear area's middle, not the screen's).
  (LatLng, double) _mapView(CameraFrame cam) {
    final proj = _proj!, plan = _plan!;
    final screenMid = Offset(_size!.width / 2, _size!.height / 2);
    final c = proj.unproject(cam.center + (screenMid - plan.focal) / cam.scale);
    return (LatLng(c.lat.clamp(-85.0, 85.0), c.lng), proj.zoomFor(cam.scale));
  }

  /// The journey camera matching where the map is now.
  CameraFrame _fromMap() {
    final proj = _proj!, plan = _plan!;
    final cam = _map.camera;
    final scale = math.pow(2, cam.zoom).toDouble() * 256 / proj.worldPx;
    final mid = proj.ofLatLng(cam.center.latitude, cam.center.longitude);
    return CameraFrame(mid - (Offset(_size!.width / 2, _size!.height / 2) - plan.focal) / scale, scale);
  }

  @override
  void onFrame() {
    final plan = _plan;
    if (!_ready || plan == null || !follow) return;
    final (center, zoom) = _mapView(cameraFor(plan.at(time)));
    _steering = true;
    _map.move(center, zoom);
    _steering = false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(builder: (context, box) {
      _build(box.biggest, bottom);
      final plan = _plan!;
      final m = plan.at(time);
      final places = widget.places;
      // The way travelled so far, and the dot's place on it.
      final travelled = <LatLng>[for (var i = 0; i <= (m.leg ?? m.arrived); i++) _ll(places[i])];
      var dot = _ll(places[m.arrived]);
      if (m.leg != null) {
        final a = places[m.leg!], b = places[m.leg! + 1];
        dot = LatLng(a.lat + (b.lat - a.lat) * m.u, a.lng + (b.lng - a.lng) * m.u);
        travelled.add(dot);
      }
      final (center, zoom) = _mapView(plan.overview);
      return Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: center,
            initialZoom: zoom,
            backgroundColor: scheme.surface,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onMapReady: () {
              _ready = true;
              onFrame();
            },
            onPositionChanged: (_, gesture) {
              if (gesture && !_steering) takeOver(_fromMap());
            },
          ),
          children: [
            ..._baseLayers(context),
            PolylineLayer(polylines: [
              Polyline(
                points: [for (final p in places) _ll(p)],
                color: scheme.primary.withValues(alpha: 0.35),
                strokeWidth: 3,
                pattern: StrokePattern.dashed(segments: const [4, 8]),
              ),
              Polyline(points: travelled, color: scheme.primary, strokeWidth: 5, strokeCap: StrokeCap.round),
            ]),
            MarkerLayer(markers: [
              for (final (i, p) in places.indexed)
                Marker(
                  point: _ll(p),
                  width: 18,
                  height: 18,
                  child: AnimatedContainer(
                    duration: 300.ms,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i <= m.arrived ? scheme.primary : scheme.surface,
                      border: Border.all(color: scheme.primary, width: 3),
                    ),
                  ),
                ),
              Marker(
                point: dot,
                width: 34,
                height: 34,
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary.withValues(alpha: 0.18)),
                  alignment: Alignment.center,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                ),
              ),
            ]),
            // Up top: the bottom is under the cards.
            _attribution(alignment: Alignment.topLeft),
          ],
        ),
        ...journeyControls(
          context,
          places: places,
          moment: m,
          trip: widget.trip,
          playing: playing,
          finished: finished,
          fraction: time / plan.duration,
          follow: follow,
          onPlay: () => playing ? pause() : play(),
          onSeek: seek,
          onFollow: () => refollow(_fromMap()),
          onOpen: widget.open,
        ),
      ]);
    });
  }
}
