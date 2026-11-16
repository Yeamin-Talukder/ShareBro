import 'dart:async';

import 'package:flutter/material.dart';
import 'anim.dart';

import '../platform/device.dart';
import '../scan/scan_controller.dart';
import '../share/receive.dart';
import '../share/notify.dart';
import '../share/send_center.dart';
import '../update/updater.dart';
import 'app_lock.dart';
import 'aurora.dart';
import 'desktop_soon.dart';
import 'explore_screen.dart';
import 'gallery_screen.dart';
import 'launch_clink.dart';
import 'glass_dock.dart';
import 'home_screen.dart';
import 'island.dart' show Island, islandNavigator;
import 'receive_screen.dart';
import 'review_screen.dart';
import 'scan_screen.dart';
import 'send_center_screen.dart';
import 'share_screen.dart';
import 'motion.dart';
import 'update_banner.dart';
import 'update_sheet.dart';
import 'desktop_gallery.dart';
import 'desktop_layout.dart';
import 'desktop_shell.dart';

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

  /// Desktop: the page the sidebar shows, and the ones opened so far.
  DesktopPage _page = DesktopPage.people;
  final Set<DesktopPage> _openedPages = {DesktopPage.people};

  /// Gallery tabs ask for photo access, so build them only when first opened.
  final Set<int> _opened = {0};
  bool _launching = true;

  StreamSubscription<Object>? _updates;
  AppLifecycleListener? _life;

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
    Notify.onOpen = _openFromNotification;
    // A tap on a notification may have started the app.
    WidgetsBinding.instance.addPostFrameCallback((_) => Notify.takeOpen());
    _startUpdates();
  }

  /// The daily update check (a few seconds after opening, and when the app
  /// comes back), its banner, and "welcome back" after an update.
  void _startUpdates() {
    final u = Updater.instance;
    _updates = u.announcements.stream.listen(UpdateBanner.show);
    _life = AppLifecycleListener(onResume: () => unawaited(u.maybeCheck()));
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      final hello = u.welcome;
      if (hello != null) {
        u.welcome = null;
        Island.toast('Updated to $hello · welcome back', icon: Icons.celebration_rounded);
      }
      unawaited(u.maybeCheck());
    });
  }

  /// A notification was tapped: show the screen it's about.
  void _openFromNotification(String target) {
    final nav = islandNavigator.currentState;
    if (!mounted || nav == null) return;
    final c = widget.controller;
    nav.popUntil((r) => r.isFirst);
    Widget? screen;
    switch (target) {
      case 'people':
        setState(() {
          _tab = 0;
          _page = DesktopPage.people;
        });
      case 'scan':
        screen = ScanScreen(controller: c);
      case 'review':
        setState(() => _tab = 0);
        screen = ReviewScreen(controller: c);
      case 'receive':
        screen = ReceiveScreen(controller: c);
      case 'transfers':
        screen = SendCenterScreen(controller: c);
      case 'update':
        showUpdateSheet(nav.context);
    }
    if (screen != null) nav.push(MaterialPageRoute(builder: (_) => screen!));
  }

  @override
  void dispose() {
    if (Notify.onOpen == _openFromNotification) Notify.onOpen = null;
    _updates?.cancel();
    _life?.dispose();
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

  /// Desktop: a sidebar and the page beside it, instead of the dock.
  Widget _desktop(BuildContext context) {
    final c = widget.controller;
    final pages = <DesktopPage, Widget>{
      for (final p in _openedPages)
        if (p != DesktopPage.folder)
          p: switch (p) {
            DesktopPage.people => HomeScreen(controller: c),
            DesktopPage.photos => PhotosTab(controller: c),
            DesktopPage.explore => ExploreTab(controller: c),
            _ => ShareTab(controller: c),
          },
    };
    final quiet = _page == DesktopPage.photos || _page == DesktopPage.folder;
    final app = Scaffold(
      backgroundColor: Colors.transparent,
      body: DesktopShell(
        controller: c,
        page: _page,
        pages: pages,
        onPage: (p) => setState(() {
          _page = p;
          _openedPages.add(p);
        }),
        // Quieter behind the photo grids, so photos keep their true colours.
        background: (child) => Aurora(intensity: quiet ? 0.3 : 1, child: child),
      ),
    );
    return Stack(children: [
      AppLockGate(controller: c, child: IncomingWatcher(controller: c, child: app)),
      if (_launching)
        LaunchClink(onDone: () => setState(() => _launching = false)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopLayout.on) return _desktop(context);
    final c = widget.controller;
    final tabs = [
      HomeScreen(controller: c),
      // On desktop the gallery is the scanned folders.
      if (Device.photoLibrary || Device.desktop) PhotosTab(controller: c) else const DesktopSoon(title: 'Photos'),
      if (Device.photoLibrary)
        AlbumsTab(controller: c)
      else if (Device.desktop)
        DesktopAlbumsTab(controller: c)
      else
        const DesktopSoon(title: 'Albums'),
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
                      // A quick fade only. Scaling and sliding the whole tab
                      // (its photo grid and glass bars) cost a full redraw
                      // every frame and made switching feel sluggish.
                      child: AnimatedOpacity(
                        opacity: _tab == i ? 1 : 0,
                        duration: 140.ms,
                        curve: Curves.easeOut,
                        child: tabs[i],
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
        LaunchClink(onDone: () => setState(() => _launching = false)),
    ]);
  }
}
