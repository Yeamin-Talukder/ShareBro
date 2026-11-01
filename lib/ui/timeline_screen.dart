import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/trip_days.dart';
import '../scan/scan_controller.dart';
import 'photo_viewer.dart';
import 'widgets.dart';

/// Photos further apart than this (km), or this many hours, start a new stop.
const _stopKm = 1.5;
const _stopGap = Duration(hours: 2);

typedef _Shot = ({String id, DateTime? at, double? lat, double? lng});

class _Stop {
  _Stop(this.number);

  final int number;
  final List<_Shot> shots = [];
  double? lat, lng;

  DateTime? get start => shots.first.at;
  DateTime? get end => shots.last.at;
}

/// A trip as a timeline: each day, split into the places you stopped at
/// (from photo time and GPS), with a little route map drawn at the top.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({
    super.key,
    required this.controller,
    required this.tripId,
    required this.tripName,
  });

  final ScanController controller;
  final int tripId;
  final String tripName;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  List<(DateTime, List<_Stop>)>? _days;
  List<_Stop> _allStops = const [];

  /// What each day was mostly about ("Beach"), by date.
  Map<DateTime, String?> _places = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shots = await widget.controller.db.tripTimeline(widget.tripId);
    final places = {
      for (final d in await tripDays(widget.controller.db, widget.tripId)) d.date: d.place,
    };
    final days = <(DateTime, List<_Stop>)>[];
    final all = <_Stop>[];
    _Stop? stop;
    for (final s in shots) {
      final at = s.at;
      if (at == null) continue;
      final day = DateTime(at.year, at.month, at.day);
      if (days.isEmpty || days.last.$1 != day) {
        days.add((day, <_Stop>[]));
        stop = null;
      }
      final far = stop != null &&
          s.lat != null &&
          stop.lat != null &&
          _km(stop.lat!, stop.lng!, s.lat!, s.lng!) > _stopKm;
      final late = stop != null && at.difference(stop.end!) > _stopGap;
      if (stop == null || far || late) {
        stop = _Stop(all.length + 1);
        days.last.$2.add(stop);
        all.add(stop);
      }
      stop.shots.add(s);
      if (stop.lat == null && s.lat != null) {
        stop.lat = s.lat;
        stop.lng = s.lng;
      }
    }
    if (mounted) {
      setState(() {
        _days = days;
        _allStops = all;
        _places = places;
      });
    }
  }

  static double _km(double a1, double o1, double a2, double o2) {
    const r = 6371.0;
    final dLat = (a2 - a1) * math.pi / 180, dLng = (o2 - o1) * math.pi / 180;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a1 * math.pi / 180) * math.cos(a2 * math.pi / 180) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  void _open(List<_Shot> shots, int i) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(
            ids: [for (final s in shots) s.id],
            initial: i,
            controller: widget.controller,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final days = _days;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final mapped = _allStops.where((s) => s.lat != null).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.tripName)),
      body: days == null
          ? const Center(child: CircularProgressIndicator())
          : days.isEmpty
              ? const EmptyIllustration(message: 'No dated photos in this trip yet.')
              : ListView(padding: const EdgeInsets.only(bottom: 32), children: [
                  if (mapped.length >= 2)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: SizedBox(
                          height: 180,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: 1400.ms,
                            curve: Curves.easeInOutCubic,
                            builder: (_, t, _) => CustomPaint(
                              painter: _RoutePainter(
                                [for (final s in mapped) Offset(s.lng!, s.lat!)],
                                t,
                                scheme,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  for (final (d, (day, stops)) in days.indexed) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_places[day] == null ? 'Day ${d + 1}' : 'Day ${d + 1} · ${_places[day]}',
                            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                        Text(formatSectionDay(day),
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                    for (final stop in stops)
                      _StopTile(stop: stop, onOpen: (i) => _open(stop.shots, i))
                          .animate()
                          .fadeIn(duration: 300.ms)
                          .moveX(begin: 16, curve: Curves.easeOutCubic),
                  ],
                ]),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({required this.stop, required this.onOpen});

  final _Stop stop;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final where = stop.lat == null
        ? 'No location'
        : '${stop.lat!.toStringAsFixed(3)}, ${stop.lng!.toStringAsFixed(3)}';
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The timeline rail with a numbered dot for this stop.
        SizedBox(
          width: 56,
          child: Stack(alignment: Alignment.topCenter, children: [
            Positioned(
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: scheme.outlineVariant),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CircleAvatar(
                radius: 13,
                backgroundColor: scheme.primary,
                child: Text('${stop.number}',
                    style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 16, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${formatTime(stop.start!)} – ${formatTime(stop.end!)} · ${stop.shots.length} photos',
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              Text(where, style: text.bodySmall),
              const SizedBox(height: 8),
              SizedBox(
                height: 84,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: stop.shots.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) => GestureDetector(
                    onTap: () => onOpen(i),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox.square(
                        dimension: 84,
                        child: Hero(
                          tag: 'photo-${stop.shots[i].id}',
                          child: AssetThumb(id: stop.shots[i].id, size: 200),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// The trip's route as dots joined in time order, drawn on progressively.
class _RoutePainter extends CustomPainter {
  _RoutePainter(this.points, this.t, this.scheme);

  /// (longitude, latitude) of each stop.
  final List<Offset> points;
  final double t;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerHighest);
    var minX = points.first.dx, maxX = minX, minY = points.first.dy, maxY = minY;
    for (final p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    const pad = 24.0;
    final spanX = math.max(maxX - minX, 1e-6), spanY = math.max(maxY - minY, 1e-6);
    final scale = math.min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanY);
    Offset at(Offset p) => Offset(
          size.width / 2 + (p.dx - (minX + maxX) / 2) * scale,
          // Latitude grows upward.
          size.height / 2 - (p.dy - (minY + maxY) / 2) * scale,
        );
    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      path.lineTo(at(p).dx, at(p).dy);
    }
    final line = Paint()
      ..color = scheme.primary
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), line);
    }
    final shown = (points.length * t).ceil();
    for (var i = 0; i < shown; i++) {
      final c = at(points[i]);
      canvas.drawCircle(c, 7, Paint()..color = scheme.primary);
      canvas.drawCircle(c, 3, Paint()..color = scheme.onPrimary);
    }
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.t != t || old.points != points;
}
