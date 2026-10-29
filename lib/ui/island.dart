import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../scan/scan_controller.dart';
import '../share/receive.dart';
import '../share/send_center.dart';
import 'file_icons.dart';
import 'motion.dart';
import 'transfer_view.dart';
import 'widgets.dart';

/// The app's navigator, so the island can open screens from above it.
final islandNavigator = GlobalKey<NavigatorState>();

/// The app's messenger: quick messages fall back to bottom bars when the
/// island is turned off.
final islandMessenger = GlobalKey<ScaffoldMessengerState>();

const _enabledKey = 'island_on';

/// Springy, like the iPhone's Dynamic Island.
const _spring = Cubic(0.2, 1.25, 0.3, 1);

enum _Kind { none, ask, receive, send, sendExpanded, scan, done, toast }

class _Toast {
  _Toast(this.text, this.icon, this.action, this.onAction);

  final String text;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;
}

/// A black pill at the top of every screen that morphs to show what's
/// happening: an incoming request (with Accept / Decline), sending or
/// receiving with a progress ring (tap to expand), scanning, a ✓ when a
/// transfer lands, and quick messages ([Island.toast]). It floats just
/// below the status bar.
class Island extends StatefulWidget {
  const Island({super.key, required this.controller, required this.child});

  final ScanController controller;
  final Widget child;

  static final _toasts = StreamController<_Toast>.broadcast();
  static final _quiet = ValueNotifier<int>(0);

  /// Off in Settings: nothing shows at the top; requests ask in a popup and
  /// messages show as bars at the bottom instead.
  static final enabled = ValueNotifier<bool>(true);

  static Future<void> load(AppDb db) async => enabled.value = (await db.setting(_enabledKey)) != '0';

  static Future<void> setEnabled(AppDb db, bool on) async {
    enabled.value = on;
    await db.setSetting(_enabledKey, on ? '1' : '0');
  }

  /// A short message in the island ("Copied", "3 moved to trash · Undo"),
  /// or a bar at the bottom when the island is off.
  static void toast(String text, {IconData icon = Icons.check_rounded, String? action, VoidCallback? onAction}) {
    if (enabled.value) {
      _toasts.add(_Toast(text, icon, action, onAction));
      return;
    }
    islandMessenger.currentState?.showSnackBar(SnackBar(
      content: Row(children: [Icon(icon, size: 18), const SizedBox(width: 10), Expanded(child: Text(text))]),
      action: action == null || onAction == null ? null : SnackBarAction(label: action, onPressed: onAction),
    ));
  }

  @override
  State<Island> createState() => _IslandState();
}

/// While a screen already shows a transfer in full, the island leaves
/// progress to it (questions and messages still appear).
class IslandQuiet extends StatefulWidget {
  const IslandQuiet({super.key, required this.child});

  final Widget child;

  @override
  State<IslandQuiet> createState() => _IslandQuietState();
}

class _IslandQuietState extends State<IslandQuiet> {
  @override
  void initState() {
    super.initState();
    Island._quiet.value++;
  }

  @override
  void dispose() {
    Island._quiet.value--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _IslandState extends State<Island> {
  ScanController get c => widget.controller;
  SendCenter get s => c.sharing;
  Receiver get r => s.receiver;

  late final StreamSubscription<_Toast> _toastSub;
  _Toast? _toast;
  (String, String, String?)? _done; // left text, right text, thumbnail id
  Timer? _transient;
  bool _expanded = false;
  Timer? _collapse;
  final Set<int> _celebrated = {};
  ReceiveSession? _celebratedSession;
  int _lastFiles = 0;
  int _bump = 0;

  @override
  void initState() {
    super.initState();
    _celebrated.addAll([
      for (final j in s.jobs)
        if (j.status == JobStatus.done) j.id,
    ]);
    _celebratedSession = r.session;
    _toastSub = Island._toasts.stream.listen((t) => _flash(toast: t));
    s.addListener(_changed);
    r.addListener(_changed);
    c.addListener(_onScan);
    Island._quiet.addListener(_changed);
    Island.enabled.addListener(_changed);
  }

  @override
  void dispose() {
    _toastSub.cancel();
    s.removeListener(_changed);
    r.removeListener(_changed);
    c.removeListener(_onScan);
    Island._quiet.removeListener(_changed);
    Island.enabled.removeListener(_changed);
    _transient?.cancel();
    _collapse?.cancel();
    super.dispose();
  }

  // Scans report every photo; the island only needs a few updates a second.
  DateTime _lastScan = DateTime(0);
  void _onScan() {
    final now = DateTime.now();
    if (c.running && now.difference(_lastScan).inMilliseconds < 250) return;
    _lastScan = now;
    _changed();
  }

  void _changed() {
    // A transfer just finished: a ✓ for a couple of seconds.
    for (final j in s.jobs) {
      if (j.status == JobStatus.done && _celebrated.add(j.id)) {
        _flash(done: ('Sent', '${j.count} to ${j.deviceAlias}', j.assetIds.firstOrNull));
      }
    }
    final session = r.session;
    if (session != null && session.finished && !session.cancelled && session != _celebratedSession) {
      _celebratedSession = session;
      _flash(done: ('Received', '${session.done.length} from ${session.from}', session.savedIds.firstOrNull));
    }
    if (mounted) setState(() {});
  }

  void _flash({_Toast? toast, (String, String, String?)? done}) {
    _transient?.cancel();
    if (done != null) Haptics.success();
    setState(() {
      _toast = toast;
      _done = done;
      _expanded = false;
    });
    _transient = Timer(Duration(milliseconds: done != null ? 2800 : 2400), () {
      if (mounted) setState(() => _toast = _done = null);
    });
  }

  SendJob? get _job {
    for (final j in s.jobs.reversed) {
      if (j.active) return j;
    }
    return null;
  }

  _Kind get _kind {
    if (!Island.enabled.value) return _Kind.none;
    final quiet = Island._quiet.value > 0;
    if (r.pending != null && !r.pending!.answered) return _Kind.ask;
    if (_toast != null) return _Kind.toast;
    if (_done != null) return _Kind.done;
    if (!quiet && r.busy) return _Kind.receive;
    if (!quiet && _job != null) return _expanded ? _Kind.sendExpanded : _Kind.send;
    if (c.running && c.total > 0) return _Kind.scan;
    return _Kind.none;
  }

  void _tap(_Kind kind) {
    Haptics.tick();
    switch (kind) {
      case _Kind.send:
        setState(() => _expanded = true);
        _collapse?.cancel();
        _collapse = Timer(const Duration(seconds: 8), () {
          if (mounted) setState(() => _expanded = false);
        });
      case _Kind.sendExpanded:
        final job = _job;
        setState(() => _expanded = false);
        if (job != null) {
          islandNavigator.currentState?.push(
            MaterialPageRoute(
              builder: (_) => TransferScreen(controller: c, job: job),
            ),
          );
        }
      case _Kind.receive:
        islandNavigator.currentState?.push(MaterialPageRoute(builder: (_) => ReceiveLiveScreen(controller: c)));
      case _Kind.toast:
        final t = _toast;
        if (t?.onAction != null) {
          t!.onAction!();
          setState(() => _toast = null);
        }
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = mq.size.width;
    // Fit around the camera hole when the phone reports one.
    // Just below the status bar: Android draws the clock, signal and
    // battery over the app, so the pill can't sit around the camera hole
    // the way the iPhone's does without running into them.
    const pillH = 38.0;
    final top = mq.viewPadding.top + 6;
    final hole = Rect.fromCenter(center: Offset(width / 2, top + pillH / 2), width: 0, height: 0);
    const gap = 10.0;
    final kind = _kind;
    final wide = math.min(width - 20, 384.0);
    const below = 14.0; // top padding inside the big states
    final (w, h, radius) = switch (kind) {
      _Kind.none => (pillH, pillH, pillH / 2),
      _Kind.ask => (wide, 160 + below, 32.0),
      _Kind.sendExpanded => (wide, 150 + below, 32.0),
      _Kind.done || _Kind.toast => (math.min(width - 40, 300.0), pillH, pillH / 2),
      _ => (math.min(width - 40, 280.0), pillH, pillH / 2),
    };

    // A little "gulp" each time a file lands.
    final files = kind == _Kind.receive ? r.session?.done.length ?? 0 : _job?.filesDone ?? 0;
    if (files != _lastFiles) {
      _lastFiles = files;
      _bump++;
    }

    return Stack(
      children: [
        widget.child,
        Positioned(
          top: top,
          left: hole.center.dx - w / 2,
          child: IgnorePointer(
            ignoring: kind == _Kind.none,
            child: AnimatedOpacity(
              opacity: kind == _Kind.none ? 0 : 1,
              duration: const Duration(milliseconds: 250),
              child:
                  GestureDetector(
                        onTap: () => _tap(kind),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 550),
                          curve: _spring,
                          width: w,
                          height: h,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(radius),
                            boxShadow: const [
                              BoxShadow(color: Color(0x73000000), blurRadius: 30, offset: Offset(0, 10)),
                            ],
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: DefaultTextStyle(
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 260),
                                switchInCurve: const Interval(0.35, 1, curve: Curves.easeOut),
                                child: KeyedSubtree(
                                  key: ValueKey(kind),
                                  child: OverflowBox(
                                    alignment: Alignment.topCenter,
                                    minWidth: 0,
                                    minHeight: 0,
                                    maxWidth: w,
                                    maxHeight: math.max(h, pillH),
                                    child: _content(kind, pillH, gap, below),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                      .animate(key: ValueKey(_bump))
                      .scaleXY(begin: _bump == 0 ? 1 : 1.05, end: 1, duration: 280.ms, curve: Curves.easeOutBack),
            ),
          ),
        ),
      ],
    );
  }

  Widget _content(_Kind kind, double pillH, double gap, double below) => switch (kind) {
    _Kind.none => const SizedBox.shrink(),
    _Kind.ask => _ask(below),
    _Kind.sendExpanded => _expandedSend(below),
    _Kind.send => _compact(
      pillH,
      gap,
      left: [
        _thumb(_job?.assetIds.firstOrNull),
        Flexible(child: _ellipsis('To ${_job?.deviceAlias ?? ''}')),
      ],
      right: _ring(_job?.progress ?? 0, const Color(0xFFFF8A6B), waiting: _job?.status != JobStatus.sending),
    ),
    _Kind.receive => _compact(
      pillH,
      gap,
      left: [
        _thumb(r.session?.savedIds.lastOrNull),
        Flexible(child: _ellipsis(r.session?.from ?? '')),
      ],
      right: _ring(_receiveProgress, const Color(0xFF22C3B0)),
    ),
    _Kind.scan => _compact(
      pillH,
      gap,
      left: [
        const _SpinningFace(),
        const SizedBox(width: 2),
        Flexible(child: _ellipsis('Scanning')),
      ],
      right: [
        Flexible(
          child: _ellipsis(
            '${_count(c.done)} / ${_count(c.total)}',
            style: const TextStyle(color: Color(0xFF22C3B0), fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    ),
    _Kind.done => _compact(
      pillH,
      gap,
      left: [
        Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(color: Color(0xFF4ADE80), shape: BoxShape.circle),
          child: const Icon(Icons.check_rounded, size: 15, color: Color(0xFF063D1A)),
        ).animate().scaleXY(begin: 0, duration: 450.ms, curve: Curves.elasticOut),
        Flexible(child: _ellipsis(_done?.$1 ?? '')),
      ],
      right: [
        Flexible(child: _ellipsis(_done?.$2 ?? '')),
        _thumb(_done?.$3),
      ],
    ),
    _Kind.toast => _compact(
      pillH,
      gap,
      left: [
        Icon(_toast?.icon, size: 18, color: Colors.white),
        Flexible(child: _ellipsis(_toast?.text ?? '')),
      ],
      right: [
        if (_toast?.action != null)
          Flexible(
            child: _ellipsis(_toast!.action!, style: const TextStyle(color: Color(0xFFFF8A6B))),
          ),
      ],
    ),
  };

  double get _receiveProgress {
    final ss = r.session;
    if (ss == null || ss.totalBytes == 0) return 0;
    return ss.bytes / ss.totalBytes;
  }

  static String _count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  Widget _ellipsis(String text, {TextStyle? style}) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: style);

  /// Content to the left and right of the camera, with the middle clear.
  Widget _compact(double h, double gap, {required List<Widget> left, required List<Widget> right}) => SizedBox(
    height: h,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Row(spacing: 7, children: left)),
          SizedBox(width: gap),
          Expanded(
            child: Row(spacing: 7, mainAxisAlignment: MainAxisAlignment.end, children: right),
          ),
        ],
      ),
    ),
  );

  Widget _thumb(String? assetId, {double size = 24}) => ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.3),
    child: SizedBox.square(
      dimension: size,
      child: assetId == null
          ? const ColoredBox(
              color: Color(0xFF2A2633),
              child: Icon(Icons.insert_drive_file_rounded, size: 14, color: Colors.white70),
            )
          : AssetThumb(id: assetId, size: (size * 3).round()),
    ),
  );

  List<Widget> _ring(double value, Color color, {bool waiting = false}) => [
    if (!waiting)
      Text(
        '${(value * 100).round()}%',
        style: TextStyle(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    SizedBox.square(
      dimension: 20,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value),
        duration: const Duration(milliseconds: 300),
        builder: (context, v, _) => CircularProgressIndicator(
          value: waiting ? null : v,
          strokeWidth: 3,
          strokeCap: StrokeCap.round,
          color: color,
          backgroundColor: Colors.white24,
        ),
      ),
    ),
  ];

  Widget _ask(double below) {
    final req = r.pending;
    if (req == null) return const SizedBox.shrink();
    final shown = req.files.take(5).toList();
    final initial = req.from.trim().isEmpty ? '?' : req.from.trim()[0].toUpperCase();
    return Padding(
      padding: EdgeInsets.fromLTRB(18, below, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _PulsingAvatar(initial: initial),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${req.from} wants to send you',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${req.summary} · ${formatBytes(req.totalBytes)} · ${req.via}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFB9B4C8), fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final f in shown) ...[FileBadge(mime: f.mime, name: f.fileName, size: 30), const SizedBox(width: 6)],
              if (req.files.length > shown.length)
                Text(
                  '+${req.files.length - shown.length}',
                  style: const TextStyle(color: Color(0xFFB9B4C8), fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _pillButton('Decline', () => _answer(req, false))),
              const SizedBox(width: 8),
              Expanded(child: _pillButton('Accept', () => _answer(req, true), main: true)),
            ],
          ),
        ],
      ),
    );
  }

  void _answer(IncomingRequest req, bool yes) {
    yes ? Haptics.success() : Haptics.tick();
    req.answer(yes);
    setState(() {});
  }

  Widget _expandedSend(double below) {
    final j = _job;
    if (j == null) return const SizedBox.shrink();
    final speed = j.speed, left = j.remaining;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, below, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _thumb(j.assetIds.firstOrNull, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sending to ${j.deviceAlias}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${j.filesDone} of ${j.count} ${j.noun}',
                      style: const TextStyle(color: Color(0xFFB9B4C8), fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: j.progress),
              duration: const Duration(milliseconds: 300),
              builder: (context, v, _) => LinearProgressIndicator(
                value: j.status == JobStatus.sending ? v : null,
                minHeight: 6,
                color: const Color(0xFFFF8A6B),
                backgroundColor: Colors.white24,
              ),
            ),
          ),
          const SizedBox(height: 8),
          DefaultTextStyle(
            style: const TextStyle(
              color: Color(0xFFB9B4C8),
              fontSize: 11.5,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${formatBytes(j.sentBytes)} of ${formatBytes(j.totalBytes)}'),
                Text(speed == null ? '' : '${formatBytes(speed.round())}/s'),
                Text(
                  left == null ? '' : '${left.inMinutes > 0 ? '${left.inMinutes}m ' : ''}${left.inSeconds % 60}s left',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _pillButton('Cancel', () {
                  Haptics.remove();
                  s.cancelJob(j);
                }),
              ),
              const SizedBox(width: 8),
              Expanded(child: _pillButton('Open', () => _tap(_Kind.sendExpanded), main: true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pillButton(String label, VoidCallback onTap, {bool main = false}) => Pressable(
    onTap: onTap,
    child: Container(
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: main ? const Color(0xFFFF8A6B) : Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Text(
        label,
        style: TextStyle(color: main ? const Color(0xFF2A120C) : Colors.white, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _PulsingAvatar extends StatelessWidget {
  const _PulsingAvatar({required this.initial});

  final String initial;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 50,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFFF8A6B), width: 2),
                ),
              )
              .animate(onPlay: (c) => c.repeat())
              .scaleXY(begin: 0.9, end: 1.25, duration: 1400.ms)
              .fadeOut(duration: 1400.ms),
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Color(0xFFFF8A6B), Color(0xFF7B61FF)]),
            ),
            child: Text(initial, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

class _SpinningFace extends StatelessWidget {
  const _SpinningFace();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [Color(0xFF22C3B0), Color(0xFF7B61FF)]),
      ),
      child: const Icon(Icons.face_rounded, size: 15, color: Colors.white),
    ).animate(onPlay: (c) => c.repeat()).rotate(duration: 2400.ms);
  }
}
