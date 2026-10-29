import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../scan/scan_controller.dart';
import '../share/receive.dart';
import '../share/send_center.dart';
import 'app_lock.dart';
import 'aurora.dart';
import 'explore_screen.dart';
import 'gallery_screen.dart';
import 'glass_dock.dart';
import 'home_screen.dart';
import 'receive_screen.dart';
import 'share_screen.dart';
import 'motion.dart';

/// Bottom navigation between People, Photos, Albums, Explore and Share. Tabs keep
/// their scroll position and filters when you switch.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  /// Gallery tabs ask for photo access, so build them only when first opened.
  final Set<int> _opened = {0};
  bool _launching = true;

  // Transfers already celebrated with the background's warm wave.
  final Set<int> _celebrated = {};
  ReceiveSession? _celebratedSession;

  @override
  void initState() {
    super.initState();
    final s = widget.controller.sharing;
    _celebrated.addAll([for (final j in s.jobs) if (j.status == JobStatus.done) j.id]);
    _celebratedSession = s.receiver.session;
    s.addListener(_checkSent);
    s.receiver.addListener(_checkReceived);
  }

  @override
  void dispose() {
    final s = widget.controller.sharing;
    s.removeListener(_checkSent);
    s.receiver.removeListener(_checkReceived);
    super.dispose();
  }

  void _checkSent() {
    for (final j in widget.controller.sharing.jobs) {
      if (j.status == JobStatus.done && _celebrated.add(j.id)) Aurora.celebrate();
    }
  }

  void _checkReceived() {
    final s = widget.controller.sharing.receiver.session;
    if (s != null && s.finished && !s.cancelled && s != _celebratedSession) {
      _celebratedSession = s;
      Aurora.celebrate();
    }
  }

  static const _items = [
    DockItem(Icons.people_outline, Icons.people, 'People'),
    DockItem(Icons.photo_outlined, Icons.photo, 'Photos'),
    DockItem(Icons.photo_album_outlined, Icons.photo_album, 'Albums'),
    DockItem(Icons.explore_outlined, Icons.explore, 'Explore'),
    DockItem(Icons.swap_horiz_rounded, Icons.swap_horiz_rounded, 'Share'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final tabs = [
      HomeScreen(controller: c),
      PhotosTab(controller: c),
      AlbumsTab(controller: c),
      ExploreTab(controller: c),
      ShareTab(controller: c),
    ];
    final media = MediaQuery.of(context);
    final app = Scaffold(
      backgroundColor: Colors.transparent,
      // Quieter behind the photo grids, so photos keep their true colours.
      body: Aurora(
        intensity: _tab == 1 || _tab == 2 ? 0.3 : 1,
        child: Stack(children: [
          // Tabs scroll underneath the floating dock, so give them room.
          MediaQuery(
            data: media.copyWith(
              padding: media.padding.copyWith(bottom: media.padding.bottom + dockClearance),
            ),
            child: Stack(children: [
              for (var i = 0; i < tabs.length; i++)
                if (_opened.contains(i))
                  Offstage(
                    offstage: _tab != i,
                    child: TickerMode(
                      enabled: _tab == i,
                      // Fade-through: the new tab rises and sharpens into place.
                      child: AnimatedScale(
                        scale: i == _tab ? 1 : 0.97,
                        duration: 320.ms,
                        curve: Curves.easeOutCubic,
                        child: AnimatedSlide(
                          offset: i == _tab ? Offset.zero : Offset(i < _tab ? -0.04 : 0.04, 0),
                          duration: 320.ms,
                          curve: Curves.easeOutCubic,
                          child: AnimatedOpacity(
                            opacity: _tab == i ? 1 : 0,
                            duration: 240.ms,
                            child: tabs[i],
                          ),
                        ),
                      ),
                    ),
                  ),
            ]),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            // Slides away while a selection bar needs the bottom edge.
            child: ValueListenableBuilder<bool>(
              valueListenable: DockVisibility.hidden,
              builder: (context, hidden, dock) => IgnorePointer(
                ignoring: hidden,
                child: AnimatedSlide(
                  offset: hidden ? const Offset(0, 1.4) : Offset.zero,
                  duration: 320.ms,
                  curve: hidden ? Curves.easeInCubic : Curves.easeOutBack,
                  child: AnimatedOpacity(opacity: hidden ? 0 : 1, duration: 220.ms, child: dock),
                ),
              ),
              child: GlassDock(
                items: _items,
                index: _tab,
                onSelect: (i) {
                  if (i == _tab) return;
                  Haptics.tick();
                  setState(() {
                    _tab = i;
                    _opened.add(i);
                  });
                },
              ),
            ),
          ),
        ]),
      ),
    );
    return Stack(children: [
      AppLockGate(controller: c, child: IncomingWatcher(controller: c, child: app)),
      if (_launching)
        _LaunchOverlay(onDone: () => setState(() => _launching = false)),
    ]);
  }
}

/// Opening animation: the logo pops in, bursts into floating faces that
/// drift toward where the People grid sits, then the whole thing fades away.
class _LaunchOverlay extends StatelessWidget {
  const _LaunchOverlay({required this.onDone});

  final VoidCallback onDone;

  static const _targets = [
    Offset(-110, -200), Offset(0, -200), Offset(110, -200),
    Offset(-110, -80), Offset(0, -80), Offset(110, -80),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final faces = [
      scheme.primaryContainer,
      scheme.tertiaryContainer,
      scheme.secondaryContainer,
    ];
    return Positioned.fill(
      child: ColoredBox(
        color: scheme.surface,
        child: Stack(alignment: Alignment.center, children: [
          for (final (i, target) in _targets.indexed)
            CircleAvatar(
              radius: 30,
              backgroundColor: faces[i % faces.length],
              child: Icon(Icons.face_rounded, size: 34, color: scheme.onPrimaryContainer),
            )
                .animate()
                .scaleXY(begin: 0, end: 1, delay: (550 + 40 * i).ms, duration: 350.ms,
                    curve: Curves.easeOutBack)
                .move(
                    begin: Offset.zero,
                    end: target,
                    delay: (550 + 40 * i).ms,
                    duration: 600.ms,
                    curve: Curves.easeOutCubic),
          // The app icon pops in with a light sweep across it, then lifts away.
          ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Image.asset('assets/icon/app_icon_1024.png', width: 120, height: 120),
          )
              .animate()
              .scaleXY(begin: 0, end: 1, duration: 600.ms, curve: Curves.elasticOut)
              .shimmer(delay: 350.ms, duration: 700.ms, color: Colors.white70)
              .then(delay: 120.ms)
              .scaleXY(end: 0.4, duration: 300.ms, curve: Curves.easeIn)
              .fadeOut(duration: 300.ms),
          Positioned(
            bottom: 120,
            child: Text('ShareBro',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800))
                .animate()
                .fadeIn(delay: 200.ms, duration: 400.ms)
                .moveY(begin: 12, curve: Curves.easeOutCubic),
          ),
        ]),
      )
          .animate(onComplete: (_) => onDone())
          .fadeOut(delay: 1300.ms, duration: 350.ms),
    );
  }
}
