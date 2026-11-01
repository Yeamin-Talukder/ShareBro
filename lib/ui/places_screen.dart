import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/db.dart' show DaySpan;
import '../data/places.dart';
import '../scan/scan_controller.dart';
import 'aurora.dart';
import 'fast_thumb.dart';
import 'journey_camera.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'real_map.dart';
import 'sections.dart';
import 'widgets.dart';

enum _View { map, journey, places }

/// Where photos were taken, on a drawn map in the app's contour style:
/// photo pins that split apart as you zoom in, the trip drawing itself in
/// order (Journey), and every place as a card. Works offline: nothing is
/// fetched, places come from the photos' own locations.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key, required this.controller, this.tripId, this.title = 'Places'});

  final ScanController controller;
  final int? tripId;
  final String title;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  List<Place>? _places;
  _View _view = _View.map;

  /// Only places visited within these dates; null for all.
  DaySpan? _dates;

  /// Every place (no date filter), for the year and month chips.
  List<Place> _everywhere = const [];

  /// Real map tiles instead of the drawn map; remembered.
  bool _real = false;
  static const _realKey = 'places_real_map';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = widget.controller;
    // Seen before and nothing changed: show it straight away.
    _places = cachedPlaces(widget.tripId, c.revision);
    _everywhere = _places ?? const [];
    final real = await c.db.setting(_realKey);
    if (mounted && real == '1') setState(() => _real = true);
    if (_places == null) await _refresh();
    // Photos scanned before locations could be read get theirs, in the
    // background; the map updates if any turn up.
    if (await c.backfillLocations() > 0) await _refresh();
  }

  Future<void> _refresh() async {
    final c = widget.controller;
    final dates = _dates;
    final everywhere = await loadPlaces(c.db, tripId: widget.tripId, revision: c.revision);
    final places = dates == null
        ? everywhere
        : await loadPlaces(c.db, tripId: widget.tripId, dates: dates, revision: c.revision);
    // A newer pick of dates may have come in meanwhile.
    if (!mounted || dates != _dates) return;
    setState(() {
      _everywhere = everywhere;
      _places = places;
    });
    // Start the pins' photos now, so the map isn't a field of blank pins.
    for (final p in places.take(80)) {
      precacheImage(FastThumb(p.cover, FastThumb.step(_pinPx), cover: true), context);
    }
  }

  /// Size pins and stop cards ask their photos at (see [PhotoPin]).
  static const _pinPx = 160.0;

  void _setDates(DaySpan? d) {
    if (d == _dates) d = null;
    Haptics.tick();
    setState(() => _dates = d);
    _refresh();
  }

  /// Quick picks: the last 30 days, each year with places, and once a
  /// year is picked, its months with places; then any range.
  Widget _dateRow(BuildContext context) {
    final now = DateTime.now();
    final times = [for (final p in _everywhere) ...p.times];
    final years = {for (final t in times) t.year}.toList()..sort((a, b) => b.compareTo(a));
    final year = _dates != null && _dates!.start.year == _dates!.end.year ? _dates!.start.year : null;
    final months = year == null
        ? <int>[]
        : ({
            for (final t in times)
              if (t.year == year) t.month,
          }.toList()..sort());
    final recent = DaySpan(now.subtract(const Duration(days: 29)), now);
    Widget chip(String label, DaySpan span) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: CapsuleChip(label: label, selected: _dates == span, onTap: () => _setDates(span)),
      ),
    );
    const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DateChip(value: _dates, onChanged: _setDates),
          ),
          if (times.any(recent.contains)) chip('Last 30 days', recent),
          for (final y in years) ...[
            chip('$y', DaySpan(DateTime(y), DateTime(y, 12, 31))),
            // That year's months, right after it.
            if (y == year)
              for (final m in months) chip('${monthNames[m - 1]} $y', DaySpan(DateTime(y, m), DateTime(y, m + 1, 0))),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final places = _places;
    return Aurora(
      intensity: 0.6,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            if (places != null && places.isNotEmpty && _view != _View.places)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Drawn'), tooltip: 'Drawn map, works offline'),
                    ButtonSegment(value: true, label: Text('Real'), tooltip: 'Real map, needs internet'),
                  ],
                  selected: {_real},
                  onSelectionChanged: (v) {
                    Haptics.tick();
                    setState(() => _real = v.single);
                    widget.controller.db.setSetting(_realKey, _real ? '1' : '0');
                  },
                ),
              ),
          ],
          bottom: places == null || (places.isEmpty && _everywhere.isEmpty)
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(52 + 44),
                  child: Column(
                    children: [
                      _dateRow(context),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: SegmentedButton<_View>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: _View.map, label: Text('Map'), icon: Icon(Icons.map_rounded)),
                            ButtonSegment(
                              value: _View.journey,
                              label: Text('Journey'),
                              icon: Icon(Icons.route_rounded),
                            ),
                            ButtonSegment(value: _View.places, label: Text('Places'), icon: Icon(Icons.place_rounded)),
                          ],
                          selected: {_view},
                          onSelectionChanged: (v) {
                            Haptics.tick();
                            setState(() => _view = v.single);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        body: places == null
            ? const Center(child: CircularProgressIndicator())
            : places.isEmpty
            ? EmptyIllustration(
                message: _everywhere.isNotEmpty
                    ? 'No places in these dates.\nTry another range.'
                    : 'No photos with a location yet.\n'
                          'Photos taken with location turned on show up here after a scan.',
              )
            : AnimatedSwitcher(
                duration: 250.ms,
                child: switch ((_view, _real)) {
                  (_View.map, false) => _MapView(key: ValueKey(('map', _dates)), places: places, open: _open),
                  (_View.map, true) => RealPlacesMap(key: ValueKey(('real map', _dates)), places: places, open: _open),
                  (_View.journey, false) => _JourneyView(
                    key: ValueKey(('journey', _dates)),
                    places: places,
                    trip: _asTrip,
                    open: _open,
                  ),
                  (_View.journey, true) => RealJourney(
                    key: ValueKey(('real journey', _dates)),
                    places: places,
                    trip: _asTrip,
                    open: _open,
                  ),
                  (_View.places, _) => _PlaceList(key: const ValueKey('list'), places: places, open: _open),
                },
              ),
      ),
    );
  }

  /// A trip, or a picked range of dates: stops count days from its start.
  bool get _asTrip => widget.tripId != null || _dates != null;

  /// A place's photos in a sheet; tap one to view it.
  void _open(Place place) {
    Haptics.lift();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => CustomScrollView(
          controller: scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '${place.photos.length} photos · ${_when(place)}',
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                ),
                itemCount: place.photos.length,
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => _viewPhotos(place.photos, i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: AssetThumb(id: place.photos[i], size: 200),
                  ),
                ).animate().fadeIn(delay: (20 * i.clamp(0, 20)).ms).moveY(begin: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _viewPhotos(List<String> ids, int index) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        transitionDuration: 300.ms,
        reverseTransitionDuration: 300.ms,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(ids: ids, initial: index, controller: widget.controller),
        ),
      ),
    );
  }
}

String _when(Place p) {
  final a = DateTime(p.first.year, p.first.month, p.first.day);
  final b = DateTime(p.last.year, p.last.month, p.last.day);
  return a == b ? formatDay(a) : formatSpan(DaySpan(a, b));
}

// ---------------------------------------------------------------------------
// The drawn map: rings like hills around each place, dotted paths between
// visits in order.

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.points,
    required this.weights,
    required this.zoom,
    required this.line,
    required this.accent,
    this.paths = true,
  });

  final List<Offset> points;
  final List<int> weights;
  final double zoom;
  final Color line, accent;
  final bool paths;

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final grow = math.sqrt(zoom).clamp(0.5, 2.5);
    for (var i = 0; i < points.length; i++) {
      // More photos, a taller hill: more rings.
      final rings = (1 + math.log(weights[i] + 1) * 1.2).round().clamp(1, 7);
      for (var k = 1; k <= rings; k++) {
        ring.color = k % 3 == 0 ? accent : line;
        final r = (10 + 13.0 * k) * grow;
        canvas.drawOval(Rect.fromCenter(center: points[i], width: r * 2.2, height: r * 1.5), ring);
      }
    }
    if (!paths || points.length < 2) return;
    final dots = Paint()..color = line.withValues(alpha: line.a * 2.2);
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1], b = points[i];
      final len = (b - a).distance;
      for (var d = 0.0; d < len; d += 7) {
        canvas.drawCircle(Offset.lerp(a, b, d / len)!, 1.1, dots);
      }
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.zoom != zoom || old.points != points || old.line != line || old.accent != accent;
}

({Color line, Color accent}) _mapColors(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  return (
    line: (dark ? Colors.white : const Color(0xFF1A1820)).withValues(alpha: 0.12),
    accent: scheme.primary.withValues(alpha: 0.35),
  );
}

// ---------------------------------------------------------------------------
// Map: photo pins that merge when they'd overlap and split as you zoom in.

class _MapView extends StatefulWidget {
  const _MapView({super.key, required this.places, required this.open});

  final List<Place> places;
  final ValueChanged<Place> open;

  @override
  State<_MapView> createState() => _MapViewState();
}

/// Pins closer than this on screen join into one.
const _pinGap = 64.0;

/// Photo pins' size on screen.
const pinSize = 56.0;

class _Cluster {
  _Cluster(this.members, this.at);

  final List<int> members;
  Offset at;
  String get key => (List.of(members)..sort()).join(',');
}

class _MapViewState extends State<_MapView> with SingleTickerProviderStateMixin {
  final _tc = TransformationController();
  late final AnimationController _fly = AnimationController(vsync: this, duration: 500.ms);
  Animation<Matrix4>? _flight;

  @override
  void initState() {
    super.initState();
    _fly.addListener(() {
      final f = _flight;
      if (f != null) _tc.value = f.value;
    });
  }

  @override
  void dispose() {
    _fly.dispose();
    _tc.dispose();
    super.dispose();
  }

  /// Zooms so [members] fill the middle of the screen; they split apart.
  void _zoomTo(List<Offset> base, Size size) {
    Haptics.tick();
    final box = Rect.fromPoints(
      base.reduce((a, b) => Offset(math.min(a.dx, b.dx), math.min(a.dy, b.dy))),
      base.reduce((a, b) => Offset(math.max(a.dx, b.dx), math.max(a.dy, b.dy))),
    );
    final now = _tc.value.getMaxScaleOnAxis();
    final fit = math.min(size.width * 0.5 / math.max(box.width, 1), size.height * 0.5 / math.max(box.height, 1));
    final scale = fit.clamp(now * 1.6, 60.0);
    final c = box.center;
    final target = Matrix4.identity()
      ..translateByDouble(size.width / 2 - c.dx * scale, size.height / 2 - c.dy * scale, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _flight = Matrix4Tween(
      begin: _tc.value,
      end: target,
    ).animate(CurvedAnimation(parent: _fly, curve: Curves.easeInOutCubic));
    _fly.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = _mapColors(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final proj = PlaceProjection(widget.places, size, Rect.fromLTRB(56, 72, size.width - 56, size.height - 56));
        final base = [for (final p in widget.places) proj.of(p)];
        final weights = [for (final p in widget.places) p.photos.length];
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 1,
                maxScale: 80,
                boundaryMargin: EdgeInsets.all(size.shortestSide),
                child: SizedBox.fromSize(
                  size: size,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
            ),
            // Drawn on screen (not zoomed as a picture), so lines stay crisp.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _tc,
                  builder: (context, _) {
                    final m = _tc.value;
                    return CustomPaint(
                      painter: _MapPainter(
                        points: [for (final b in base) MatrixUtils.transformPoint(m, b)],
                        weights: weights,
                        zoom: m.getMaxScaleOnAxis(),
                        line: colors.line,
                        accent: colors.accent,
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _tc,
                builder: (context, _) {
                  final m = _tc.value;
                  final screen = [for (final b in base) MatrixUtils.transformPoint(m, b)];
                  // Biggest places first, so they anchor their clusters.
                  final order = List.generate(widget.places.length, (i) => i)
                    ..sort((a, b) => weights[b].compareTo(weights[a]));
                  final clusters = <_Cluster>[];
                  for (final i in order) {
                    final near = clusters.where((c) => (c.at - screen[i]).distance < _pinGap).firstOrNull;
                    if (near == null) {
                      clusters.add(_Cluster([i], screen[i]));
                    } else {
                      near.members.add(i);
                    }
                  }
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final c in clusters)
                        Positioned(
                          key: ValueKey(c.key),
                          left: c.at.dx - pinSize / 2,
                          top: c.at.dy - pinSize - 8,
                          child: PhotoPin(
                            cover: widget.places[c.members.first].cover,
                            count: c.members.fold(0, (n, i) => n + weights[i]),
                            label: c.members.length == 1 ? widget.places[c.members.first].name : null,
                            onTap: () => c.members.length == 1
                                ? widget.open(widget.places[c.members.first])
                                : _zoomTo([for (final i in c.members) base[i]], size),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Positioned(
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: FloatingActionButton.small(
                heroTag: null,
                tooltip: 'Show everything',
                onPressed: () {
                  Haptics.tick();
                  _flight = Matrix4Tween(
                    begin: _tc.value,
                    end: Matrix4.identity(),
                  ).animate(CurvedAnimation(parent: _fly, curve: Curves.easeInOutCubic));
                  _fly.forward(from: 0);
                },
                child: const Icon(Icons.zoom_out_map_rounded),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A rounded photo on a little stem, with how many photos it stands for.
class PhotoPin extends StatelessWidget {
  const PhotoPin({super.key, required this.cover, required this.count, required this.onTap, this.label});

  final String cover;
  final int count;
  final String? label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rim = scheme.brightness == Brightness.dark ? const Color(0xFF2A282E) : Colors.white;
    return GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: pinSize,
            height: pinSize + 8,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                Positioned(
                  bottom: 0,
                  child: Transform.rotate(
                    angle: math.pi / 4,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(color: rim, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
                Container(
                  width: pinSize,
                  height: pinSize,
                  decoration: BoxDecoration(
                    color: rim,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4))],
                  ),
                  padding: const EdgeInsets.all(3),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: AssetThumb(id: cover, size: 160),
                  ),
                ),
                Positioned(
                  top: -8,
                  right: -10,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 24),
                    height: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: rim, width: 2),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (label != null)
                  Positioned(
                    top: pinSize + 12,
                    child: Text(
                      label!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                        shadows: [Shadow(color: scheme.surface, blurRadius: 4)],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        )
        .animate()
        .scaleXY(begin: 0.3, duration: 380.ms, curve: Curves.easeOutBack, alignment: Alignment.bottomCenter)
        .fadeIn(duration: 200.ms);
  }
}

// ---------------------------------------------------------------------------
// Journey: filmed like a travel video. The camera pulls back to show each
// leg, follows the dot, and pushes in on the place it arrives at. Pinch or
// drag to look around; Follow hands the camera back.

/// "Day 2 · 13 Jun" on a trip, else the date.
String journeyDay(List<Place> places, Place p, {required bool trip}) {
  if (!trip) return formatDay(p.first);
  final start = places.first.first;
  final day =
      DateTime(
        p.first.year,
        p.first.month,
        p.first.day,
      ).difference(DateTime(start.year, start.month, start.day)).inDays +
      1;
  return 'Day $day · ${formatDay(p.first)}';
}

/// Room the stop card and the player take at the bottom.
const journeyControlsHeight = 190.0;

/// The journey's plan for a screen of [size]: places laid out in the area
/// above the controls, and how close each close-up gets.
({PlaceProjection proj, JourneyPlan plan, List<Offset> stops}) journeySetup(
  List<Place> places,
  Size size,
  double bottomInset,
) {
  final clear = Rect.fromLTRB(24, 24, size.width - 24, size.height - bottomInset - journeyControlsHeight);
  final proj = PlaceProjection(places, size, clear);
  final stops = [for (final p in places) proj.of(p)];
  final radius = [
    for (var i = 0; i < stops.length; i++)
      () {
        // About a kilometre around the place, or more when its neighbours
        // are far, so the close-up still shows where it sits.
        var nearest = double.infinity;
        for (var j = 0; j < stops.length; j++) {
          if (j != i) nearest = math.min(nearest, (stops[j] - stops[i]).distance);
        }
        final km = proj.unitsPerMeter(places[i].lat) * 500;
        return nearest.isFinite ? math.max(km, nearest * 0.25) : km;
      }(),
  ];
  // Street level at most (web zoom 17).
  final maxScale = math.max(1.0, math.pow(2, 17 - proj.zoomFor(1)).toDouble());
  return (
    proj: proj,
    stops: stops,
    plan: JourneyPlan(stops: stops, closeRadius: radius, focal: clear.center, view: clear.size, maxScale: maxScale),
  );
}

class _JourneyView extends StatefulWidget {
  const _JourneyView({super.key, required this.places, required this.trip, required this.open});

  final List<Place> places;

  /// On a trip, stops are "Day 2"; otherwise they're dates.
  final bool trip;
  final ValueChanged<Place> open;

  @override
  State<_JourneyView> createState() => _JourneyViewState();
}

class _JourneyViewState extends State<_JourneyView> with SingleTickerProviderStateMixin, JourneyClock {
  // Route geometry for the current size, in base points.
  Size? _size;
  JourneyPlan? _plan;
  List<Offset> _stops = const [];
  Path _route = Path();
  List<double> _stopAt = const [0];

  /// The camera drawn last frame, and where a pinch started.
  CameraFrame? _shown;
  CameraFrame? _pinchFrom;
  Offset _pinchAt = Offset.zero;

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
    _plan = setup.plan;
    _stops = setup.stops;
    final path = Path()..moveTo(_stops.first.dx, _stops.first.dy);
    final at = <double>[0];
    var length = 0.0;
    for (var i = 1; i < _stops.length; i++) {
      final a = _stops[i - 1], b = _stops[i];
      // A gentle bend, alternating sides, like a road.
      final mid = Offset.lerp(a, b, 0.5)!;
      final n = Offset(-(b - a).dy, (b - a).dx) / math.max((b - a).distance, 1e-9);
      final ctrl = mid + n * (b - a).distance * 0.18 * (i.isOdd ? 1 : -1);
      final leg = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      path.quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      length += leg.computeMetrics().fold(0.0, (s, m) => s + m.length);
      at.add(length);
    }
    _route = path;
    _stopAt = [for (final a in at) length == 0 ? 0 : a / length];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = _mapColors(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, box) {
        _build(box.biggest, bottom);
        final plan = _plan!;
        final m = plan.at(time);
        final cam = cameraFor(m);
        _shown = cam;
        final focal = plan.focal;
        final matrix = Matrix4.identity()
          ..translateByDouble(focal.dx - cam.center.dx * cam.scale, focal.dy - cam.center.dy * cam.scale, 0, 1)
          ..scaleByDouble(cam.scale, cam.scale, 1, 1);
        final screen = [for (final b in _stops) cam.toScreen(b, focal)];
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (d) {
                  _pinchFrom = _shown;
                  _pinchAt = d.localFocalPoint;
                  takeOver(_shown!);
                },
                onScaleUpdate: (d) {
                  final from = _pinchFrom;
                  if (from == null) return;
                  final s = (from.scale * d.scale).clamp(0.6, plan.maxScale * 1.5);
                  // Keep the spot under the fingers under the fingers.
                  final anchor = from.center + (_pinchAt - focal) / from.scale;
                  setState(() => manual = CameraFrame(anchor - (d.localFocalPoint - focal) / s, s));
                },
                child: CustomPaint(
                  painter: _MapPainter(
                    points: screen,
                    weights: [for (final p in widget.places) p.photos.length],
                    zoom: cam.scale,
                    line: colors.line,
                    accent: colors.accent,
                    paths: false,
                  ),
                  foregroundPainter: _RoutePainter(
                    route: _route.transform(matrix.storage),
                    t: m.route(_stopAt),
                    stops: screen,
                    reached: m.arrived,
                    color: scheme.primary,
                    stopFill: scheme.surface,
                  ),
                ),
              ),
            ),
            ...journeyControls(
              context,
              places: widget.places,
              moment: m,
              trip: widget.trip,
              playing: playing,
              finished: finished,
              fraction: time / plan.duration,
              follow: follow,
              onPlay: () => playing ? pause() : play(),
              onSeek: seek,
              onFollow: () => refollow(_shown!),
              onOpen: widget.open,
            ),
          ],
        );
      },
    );
  }
}

/// The journey's controls, over either map: the place just reached, the
/// player, and Follow once the map was moved by hand.
List<Widget> journeyControls(
  BuildContext context, {
  required List<Place> places,
  required JourneyMoment moment,
  required bool trip,
  required bool playing,
  required bool finished,
  required double fraction,
  required bool follow,
  required VoidCallback onPlay,
  required ValueChanged<double> onSeek,
  required VoidCallback onFollow,
  required ValueChanged<Place> onOpen,
}) {
  final scheme = Theme.of(context).colorScheme;
  final bottom = MediaQuery.paddingOf(context).bottom;
  final place = places[moment.arrived];
  return [
    Positioned(
      top: 12,
      right: 12,
      child: AnimatedSwitcher(
        duration: 250.ms,
        transitionBuilder: (child, a) => ScaleTransition(
          scale: a,
          child: FadeTransition(opacity: a, child: child),
        ),
        child: follow
            ? const SizedBox.shrink()
            : FilledButton.tonalIcon(
                key: const ValueKey('follow'),
                onPressed: onFollow,
                icon: const Icon(Icons.center_focus_strong_rounded),
                label: const Text('Follow'),
              ),
      ),
    ),
    Positioned(
      left: 16,
      right: 16,
      bottom: bottom + 88,
      child: AnimatedSwitcher(
        duration: 350.ms,
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a),
            child: child,
          ),
        ),
        child: StopCard(
          key: ValueKey(moment.arrived),
          place: place,
          day: journeyDay(places, place, trip: trip),
          onTap: () => onOpen(place),
        ),
      ),
    ),
    Positioned(
      left: 16,
      right: 16,
      bottom: bottom + 16,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play the journey',
              onPressed: onPlay,
              icon: Icon(
                playing
                    ? Icons.pause_rounded
                    : finished
                    ? Icons.replay_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            Expanded(
              child: Slider(value: fraction.clamp(0.0, 1.0), onChanged: onSeek),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '${moment.arrived + 1}/${places.length}',
                style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    ),
  ];
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.route,
    required this.t,
    required this.stops,
    required this.reached,
    required this.color,
    required this.stopFill,
  });

  /// The whole route, in screen points.
  final Path route;

  /// 0..1 along it.
  final double t;
  final List<Offset> stops;
  final int reached;
  final Color color, stopFill;

  @override
  void paint(Canvas canvas, Size size) {
    // The whole way, faint; the part travelled, solid.
    final ghost = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(route, ghost);
    final metrics = route.computeMetrics().toList();
    final length = metrics.fold(0.0, (s, m) => s + m.length);
    final done = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    var travelled = 0.0;
    Offset? walker;
    for (final m in metrics) {
      final want = length * t - travelled;
      if (want > 0) {
        canvas.drawPath(m.extractPath(0, math.min(want, m.length)), done);
        walker = m.getTangentForOffset(math.min(want, m.length))?.position;
      }
      travelled += m.length;
    }
    for (var i = 0; i < stops.length; i++) {
      final hit = i <= reached;
      canvas.drawCircle(stops[i], hit ? 8 : 6, Paint()..color = hit ? color : stopFill);
      canvas.drawCircle(
        stops[i],
        hit ? 8 : 6,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    final w = walker ?? (stops.isEmpty ? null : stops.first);
    if (w != null) {
      canvas.drawCircle(w, 16, Paint()..color = color.withValues(alpha: 0.18));
      canvas.drawCircle(w, 9, Paint()..color = Colors.white);
      canvas.drawCircle(w, 6.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.t != t || old.route != route || old.reached != reached;
}

class StopCard extends StatelessWidget {
  const StopCard({super.key, required this.place, required this.day, required this.onTap});

  final Place place;
  final String day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbs = place.photos.take(3).toList();
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 24, offset: Offset(0, 10))],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 58 + 40.0 * (thumbs.length - 1),
              height: 58,
              child: Stack(
                children: [
                  for (final (i, id) in thumbs.indexed)
                    Positioned(
                      left: 40.0 * i,
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.surfaceContainerLowest, width: 3),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: AssetThumb(id: id, size: 160),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    day.toUpperCase(),
                    style: TextStyle(
                      color: scheme.primary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  Text(
                    place.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                  Text('${place.photos.length} photos', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Places: every place as a card, most photos first.

class _PlaceList extends StatelessWidget {
  const _PlaceList({super.key, required this.places, required this.open});

  final List<Place> places;
  final ValueChanged<Place> open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = _mapColors(context);
    final sorted = List.of(places)..sort((a, b) => b.photos.length.compareTo(a.photos.length));
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 24),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final p = sorted[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Pressable(
            onTap: () => open(p),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox.square(
                      dimension: 84,
                      child: CustomPaint(
                        painter: _MapPainter(
                          points: const [Offset(42, 46)],
                          weights: [p.photos.length],
                          zoom: 0.5,
                          line: colors.line,
                          accent: colors.accent,
                          paths: false,
                        ),
                        child: Center(
                          child: Container(
                            width: 16,
                            height: 16,
                            margin: const EdgeInsets.only(top: 8),
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                        Text(
                          '${p.photos.length} photos · ${_when(p)}',
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            for (final id in p.photos.take(5))
                              Padding(
                                padding: const EdgeInsets.only(right: 3),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(7),
                                  child: SizedBox.square(dimension: 30, child: AssetThumb(id: id, size: 90)),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ).animate().fadeIn(delay: (50 * i.clamp(0, 10)).ms).moveY(begin: 12, curve: Curves.easeOutCubic),
        );
      },
    );
  }
}
