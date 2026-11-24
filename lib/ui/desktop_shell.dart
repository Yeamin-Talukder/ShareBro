import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../scan/desktop_folders.dart';
import '../scan/scan_controller.dart';
import 'desktop_gallery.dart';
import 'desktop_layout.dart';
import 'active_shares.dart';
import 'group_screen.dart';
import 'island.dart' show desktopPages;
import 'scan_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';
import 'people_sync_screen.dart';
import '../update/updater.dart';
import 'face_image.dart';

/// The pages the sidebar switches between. Folders get a page each.
enum DesktopPage { people, photos, explore, share, folder }

/// Opens things in the desktop window from outside it (a notification, the
/// update banner).
abstract final class DesktopNav {
  static _DesktopShellState? _shell;

  /// Shows Settings beside the sidebar, at [section] (see
  /// [SettingsScreen.section]). False when there's no desktop window.
  static bool openSettings([String? section]) {
    final shell = _shell;
    if (shell == null || !shell.mounted) return false;
    shell._openSettings(section);
    return true;
  }

  /// Back, as in a browser: closes the page on top, or (with [pages]) goes
  /// to the main page shown before. False when there's nowhere to go.
  static bool back({bool pages = true}) {
    final shell = _shell;
    return shell != null && shell.mounted && shell._back(pages: pages);
  }

  /// Forward: opens again what Back just left.
  static bool forward() {
    final shell = _shell;
    return shell != null && shell.mounted && shell._forwardGo();
  }
}

/// A step Forward can take again: reopen a page, or show a main page.
class _Fwd {
  _Fwd.route(Route<dynamic> Function() this.make)
      : page = null,
        folder = null;
  _Fwd.page(DesktopPage this.page, this.folder) : make = null;

  final Route<dynamic> Function()? make;
  final DesktopPage? page;
  final _Folder? folder;
}

/// Names of the pages the sidebar opens on top of the main pages; the
/// sidebar highlights the one showing.
abstract final class _Opened {
  static const settings = 'settings';
  static const tripGroup = 'trip-group';
  static const syncPeople = 'sync-people';
  static const search = 'search';
  static const scan = 'scan';

  /// The ones with a row of their own in the sidebar.
  static const inSidebar = {settings, tripGroup, syncPeople};
}

/// ShareBro's desktop window: a sidebar on the left (People, Photos,
/// Explore, sharing, the scanned folders, the running scan and settings)
/// and the page on the right. Below [DesktopLayout.wideFrom] the sidebar
/// folds into an icon rail. Replaces the phone's floating dock.
///
/// Every page opens beside the sidebar: the content area has its own
/// navigator ([desktopPages]), so a person, a photo or Settings never
/// covers the sidebar. Dialogs still cover the whole window.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.controller,
    required this.page,
    required this.onPage,
    required this.pages,
    this.background,
  });

  final ScanController controller;

  /// The page shown; [DesktopPage.folder] shows the folder picked in the
  /// sidebar.
  final DesktopPage page;
  final ValueChanged<DesktopPage> onPage;

  /// The People, Photos, Explore and Share pages, built once and kept.
  final Map<DesktopPage, Widget> pages;

  /// Wraps the page area (the contour background).
  final Widget Function(Widget child)? background;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  ScanController get c => widget.controller;

  List<_Folder> _folders = const [];
  _Folder? _folder;
  int? _people, _photos;
  Timer? _reload;
  bool _wasRunning = false;

  /// Hero animations (a face growing into a person's page) inside the
  /// content area's navigator.
  final _hero = HeroController(createRectTween: (b, e) => MaterialRectArcTween(begin: b, end: e));
  late final _observer = _StackObserver(_stackChanged, onPush: _pushed);

  /// The name of the sidebar page opened over the main pages, if any.
  String? _opened;

  // ---- Back and forward, as in a browser ----

  /// Main pages shown before this one, and what Forward can reopen.
  final List<(DesktopPage, _Folder?)> _pageBack = [];
  final List<_Fwd> _forward = [];

  /// Forward is reopening a page (which mustn't clear Forward).
  bool _replaying = false;

  bool get _canBack => (_pages?.canPop() ?? false) || _pageBack.isNotEmpty;
  bool get _canForward => _forward.isNotEmpty;

  /// A way to open [r] again, for Forward.
  static Route<dynamic> Function()? _remake(Route<dynamic> r) {
    if (r is MaterialPageRoute) {
      final build = r.builder, settings = r.settings;
      return () => MaterialPageRoute<dynamic>(builder: build, settings: settings);
    }
    if (r is PageRouteBuilder) {
      final b = r;
      return () => PageRouteBuilder<dynamic>(
            settings: b.settings,
            opaque: b.opaque,
            pageBuilder: b.pageBuilder,
            transitionsBuilder: b.transitionsBuilder,
            transitionDuration: b.transitionDuration,
            reverseTransitionDuration: b.reverseTransitionDuration,
          );
    }
    return null;
  }

  bool _back({bool pages = true}) {
    final nav = _pages;
    if (nav != null && nav.canPop()) {
      Route<dynamic>? top;
      nav.popUntil((r) {
        top = r;
        return true;
      });
      // A sheet or menu on top handles its own closing.
      if (top is! PageRoute) return false;
      final again = _remake(top!);
      nav.maybePop().then((popped) {
        if (popped && again != null && mounted) _forward.add(_Fwd.route(again));
      });
      return true;
    }
    if (!pages || _pageBack.isEmpty) return false;
    final (page, folder) = _pageBack.removeLast();
    _forward.add(_Fwd.page(widget.page, _folder));
    _show(page, folder);
    return true;
  }

  bool _forwardGo() {
    if (_forward.isEmpty) return false;
    final f = _forward.removeLast();
    final make = f.make;
    if (make != null) {
      _replaying = true;
      _pages?.push(make());
      _replaying = false;
    } else {
      _pageBack.add((widget.page, _folder));
      _show(f.page!, f.folder);
    }
    return true;
  }

  /// A page opened by anything but Forward starts a new path: nothing to
  /// go forward to any more.
  void _pushed() {
    if (!_replaying) _forward.clear();
  }

  // The two-finger swipe: how far it has gone sideways (+ back, − forward).
  static const _swipeTrigger = 110.0;
  final _swipe = ValueNotifier<double>(0);
  bool _swipeOn = false, _swipeDecided = false;

  void _swipeStart(PointerPanZoomStartEvent e) {
    _swipeOn = !NavSwipe.take();
    _swipeDecided = false;
    _swipe.value = 0;
  }

  void _swipeUpdate(PointerPanZoomUpdateEvent e) {
    if (!_swipeOn) return;
    // A pinch is a zoom, not a swipe.
    if ((e.scale - 1).abs() > 0.03) return _swipeCancel();
    final d = e.pan;
    if (!_swipeDecided) {
      if (d.distance < 12) return;
      _swipeDecided = true;
      // Mostly up or down: that's scrolling.
      if (d.dy.abs() > d.dx.abs() * 0.8) {
        _swipeOn = false;
        return;
      }
    }
    final dx = d.dx;
    final can = dx > 0 ? _canBack : _canForward;
    _swipe.value = can ? dx : 0;
  }

  void _swipeEnd(PointerPanZoomEndEvent e) {
    final s = _swipe.value;
    _swipeOn = false;
    _swipe.value = 0;
    if (s.abs() < _swipeTrigger) return;
    s > 0 ? _back() : _forwardGo();
  }

  void _swipeCancel() {
    _swipeOn = false;
    _swipe.value = 0;
  }

  /// Something scrolled sideways under the fingers: the swipe was for it.
  bool _sidewaysScroll(ScrollNotification n) {
    if (_swipeOn && n.metrics.axis == Axis.horizontal && n is ScrollUpdateNotification) _swipeCancel();
    return false;
  }

  @override
  void initState() {
    super.initState();
    DesktopNav._shell = this;
    c.addListener(_changed);
    c.sharing.addListener(_sharingChanged);
    c.sharing.receiver.addListener(_sharingChanged);
    c.sharing.server.addListener(_sharingChanged);
    _load();
  }

  @override
  void dispose() {
    if (DesktopNav._shell == this) DesktopNav._shell = null;
    _hero.dispose();
    _swipe.dispose();
    _reload?.cancel();
    c.removeListener(_changed);
    c.sharing.removeListener(_sharingChanged);
    c.sharing.receiver.removeListener(_sharingChanged);
    c.sharing.server.removeListener(_sharingChanged);
    super.dispose();
  }

  void _sharingChanged() {
    if (mounted) setState(() {});
  }

  /// The scan reports every photo; counts and folders only need a refresh
  /// now and then (and right when a scan starts or ends).
  void _changed() {
    if (!mounted) return;
    if (c.running != _wasRunning) {
      _wasRunning = c.running;
      _load();
    } else {
      _reload ??= Timer(const Duration(seconds: 3), () {
        _reload = null;
        _load();
      });
    }
    setState(() {});
  }

  Future<void> _load() async {
    final folders = <_Folder>[];
    for (final t in await c.db.trips()) {
      final path = desktopFolderOf(t.albumId);
      if (path == null) continue;
      final ids = await c.db.photosIn(tripId: t.id);
      folders.add(_Folder(t.id, t.name, path, ids.firstOrNull, ids.length));
    }
    final people = await c.db.people();
    final photos = await c.db.photosIn();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _folder = _folder == null ? null : folders.where((f) => f.tripId == _folder!.tripId).firstOrNull ?? _folder;
      _people = people.length;
      _photos = photos.length;
    });
  }

  /// The content area's pages changed: which sidebar page is open? Read
  /// after the frame, as pushes can happen while the navigator builds.
  void _stackChanged(List<Route<dynamic>> stack) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final opened = stack.length > 1 ? stack[1].settings.name : null;
      if (opened != _opened) setState(() => _opened = opened);
    });
  }

  NavigatorState? get _pages => desktopPages.currentState;

  /// Back to the main pages, closing whatever was opened over them.
  void _closeOpened() => _pages?.popUntil((r) => r.isFirst);

  void _go(DesktopPage page, [_Folder? folder]) {
    final same = page == widget.page && folder?.tripId == _folder?.tripId;
    if (!same) {
      _pageBack.add((widget.page, _folder));
      if (_pageBack.length > 50) _pageBack.removeAt(0);
      _forward.clear();
    }
    _show(page, folder);
  }

  /// Shows a main page (closing anything opened over it).
  void _show(DesktopPage page, _Folder? folder) {
    _closeOpened();
    setState(() => _folder = folder);
    widget.onPage(page);
  }

  void _openSettings([String? section]) =>
      _push(SettingsScreen(controller: c, section: section), name: _Opened.settings, fresh: true);

  Future<void> _addFolder() async {
    final folder = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder of photos to scan');
    if (folder == null || !mounted) return;
    final found = await c.scanDesktopFolder(folder);
    if (!mounted) return;
    if (found == 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(c.running
              ? 'A scan is already running. Try again when it finishes.'
              : 'No photos in that folder (JPEG, PNG, WebP, GIF or BMP).')));
      return;
    }
    _push(ScanScreen(controller: c), name: _Opened.scan);
  }

  /// Opens [screen] beside the sidebar. A named one replaces whatever was
  /// opened from the sidebar before; if it's already showing it stays as it
  /// is, unless [fresh].
  void _push(Widget screen, {required String name, bool fresh = false}) {
    final nav = _pages;
    if (nav == null) return;
    if (_opened == name && !fresh) return;
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(settings: RouteSettings(name: name), builder: (_) => screen));
  }

  void _search() => _push(SearchScreen(controller: c), name: _Opened.search);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= DesktopLayout.wideFrom;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final folder = widget.page == DesktopPage.folder ? _folder : null;
    Widget content = Stack(children: [
      for (final e in widget.pages.entries)
        Offstage(
          offstage: e.key != widget.page,
          child: TickerMode(enabled: e.key == widget.page, child: e.value),
        ),
      if (folder != null)
        DesktopFolderPage(
          key: ValueKey(folder.tripId),
          controller: c,
          tripId: folder.tripId,
          name: folder.name,
          path: folder.path,
        ),
    ]);
    content = widget.background?.call(content) ?? content;
    // The content area: its own navigator, sized to the area (not the
    // window) so pages centre and pick their layout by the room they have.
    final area = LayoutBuilder(
      builder: (context, box) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: Size(box.maxWidth, box.maxHeight)),
        child: _Content(
          content: content,
          child: HeroControllerScope(
            controller: _hero,
            child: Navigator(
              key: desktopPages,
              observers: [_observer],
              onGenerateInitialRoutes: (_, _) => [
                PageRouteBuilder<void>(
                  settings: const RouteSettings(name: '/'),
                  pageBuilder: (_, _, _) => const _MainPages(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Two fingers sideways on a touchpad: back or forward, with an arrow
    // that slides in from the edge (as in Chrome).
    final swipeable = Listener(
      onPointerPanZoomStart: _swipeStart,
      onPointerPanZoomUpdate: _swipeUpdate,
      onPointerPanZoomEnd: _swipeEnd,
      child: NotificationListener<ScrollNotification>(
        onNotification: _sidewaysScroll,
        // Fills the room beside the sidebar: the arrow layer on top is
        // empty most of the time and mustn't decide the size.
        child: Stack(fit: StackFit.expand, children: [
          area,
          ValueListenableBuilder<double>(
            valueListenable: _swipe,
            builder: (context, s, _) => s == 0 ? const SizedBox.shrink() : _SwipeArrow(swipe: s, trigger: _swipeTrigger),
          ),
        ]),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _go(DesktopPage.people),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _go(DesktopPage.photos),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _go(DesktopPage.explore),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _go(DesktopPage.share),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            _push(SettingsScreen(controller: c), name: _Opened.settings),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _addFolder,
      },
      child: Focus(
        autofocus: true,
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: wide ? DesktopLayout.sidebarWidth : DesktopLayout.railWidth,
            decoration: BoxDecoration(
              color: Mac.sidebar(context),
              border: Border(
                right: BorderSide(color: dark ? const Color(0x33000000) : Mac.hairlineLight, width: dark ? 1 : 0.5),
              ),
            ),
            child: _sidebar(context, wide),
          ),
          Expanded(child: swipeable),
        ]),
      ),
    );
  }

  Widget _sidebar(BuildContext context, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    // Links, sends and receives going on now (the live badge).
    final busy = activeShareCount(c);
    // A page opened from the sidebar (Settings, Trip group…) is the
    // selected row; otherwise the main page is, even with a person or a
    // photo opened over it.
    final opened = _Opened.inSidebar.contains(_opened) ? _opened : null;
    final page = opened == null ? widget.page : null;
    Widget nav(IconData icon, IconData selectedIcon, String label, DesktopPage p,
            {String? count, int live = 0, String? keys}) =>
        _NavItem(
          icon: icon,
          selectedIcon: selectedIcon,
          label: label,
          wide: wide,
          selected: page == p,
          count: count,
          live: live,
          tooltip: keys == null ? label : '$label  ($keys)',
          onTap: () => _go(p),
        );
    return ClipRect(
      child: Padding(
        padding: EdgeInsets.fromLTRB(wide ? 10 : 10, 8, wide ? 10 : 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Brand(wide: wide),
          const SizedBox(height: 4),
          if (wide) _SearchField(onTap: _search) else _NavIcon(icon: Icons.search_rounded, tooltip: 'Search  (Ctrl+K)', onTap: _search),
          Expanded(
            child: ListView(padding: const EdgeInsets.only(bottom: 8), children: [
              _Group('Library', wide: wide),
              nav(Icons.people_outline_rounded, Icons.people_rounded, 'People', DesktopPage.people,
                  count: _people?.toString(), keys: 'Ctrl+1'),
              nav(Icons.photo_outlined, Icons.photo_rounded, 'Photos', DesktopPage.photos,
                  count: _photos == null ? null : _thousands(_photos!), keys: 'Ctrl+2'),
              nav(Icons.explore_outlined, Icons.explore_rounded, 'Explore', DesktopPage.explore, keys: 'Ctrl+3'),
              _Group('Sharing', wide: wide),
              nav(Icons.swap_horiz_rounded, Icons.swap_horiz_rounded, 'Send & receive', DesktopPage.share,
                  live: busy, keys: 'Ctrl+4'),
              _NavItem(
                icon: Icons.diversity_3_outlined,
                selectedIcon: Icons.diversity_3_rounded,
                label: 'Trip group',
                wide: wide,
                selected: opened == _Opened.tripGroup,
                tooltip: 'Trip group',
                onTap: () => _push(TripGroupScreen(controller: c), name: _Opened.tripGroup),
              ),
              _NavItem(
                icon: Icons.sync_alt_rounded,
                selectedIcon: Icons.sync_alt_rounded,
                label: 'Sync people',
                wide: wide,
                selected: opened == _Opened.syncPeople,
                tooltip: "Swap who's who with your other devices",
                onTap: () => _push(PeopleSyncScreen(controller: c), name: _Opened.syncPeople),
              ),
              _Group('Folders', wide: wide),
              for (final f in _folders)
                _NavItem(
                  icon: Icons.folder_outlined,
                  selectedIcon: Icons.folder_rounded,
                  cover: f.cover,
                  label: f.name,
                  wide: wide,
                  selected: page == DesktopPage.folder && _folder?.tripId == f.tripId,
                  count: _thousands(f.count),
                  tooltip: f.path,
                  onTap: () => _go(DesktopPage.folder, f),
                ),
              _NavItem(
                icon: Icons.create_new_folder_outlined,
                selectedIcon: Icons.create_new_folder_rounded,
                label: 'Add a folder',
                wide: wide,
                selected: false,
                faint: true,
                tooltip: 'Add a folder of photos',
                onTap: _addFolder,
              ),
            ]),
          ),
          // What's being shared right now, each with a Stop.
          SharingNowCard(controller: c, wide: wide),
          if (c.running)
            wide
                ? _ScanCard(controller: c, onOpen: () => _push(ScanScreen(controller: c), name: _Opened.scan))
                : _ScanRing(controller: c, onOpen: () => _push(ScanScreen(controller: c), name: _Opened.scan)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 0.5, thickness: 0.5, color: Mac.hairline(context)),
          ),
          ListenableBuilder(
            listenable: Updater.instance,
            builder: (context, _) => _Profile(
              wide: wide,
              thumb: c.profile.thumb,
              accent: scheme.primary,
              selected: opened == _Opened.settings,
              update: Updater.instance.hasUpdate,
              onTap: () => _push(SettingsScreen(controller: c), name: _Opened.settings),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Hands the main pages (built by the shell) to the content navigator's
/// first route, which is built once and so can't take them directly.
class _Content extends InheritedWidget {
  const _Content({required this.content, required super.child});

  final Widget content;

  @override
  bool updateShouldNotify(_Content old) => content != old.content;
}

class _MainPages extends StatelessWidget {
  const _MainPages();

  @override
  Widget build(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Content>()!.content;
}

/// The round arrow of a two-finger swipe: slides in from the left edge
/// (back) or the right (forward) and fills with the accent once letting go
/// will go there.
class _SwipeArrow extends StatelessWidget {
  const _SwipeArrow({required this.swipe, required this.trigger});

  final double swipe, trigger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final back = swipe > 0;
    final t = (swipe.abs() / trigger).clamp(0.0, 1.0);
    final ready = t >= 1;
    final x = -48 + 72 * Curves.easeOutCubic.transform(t);
    final arrow = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ready ? scheme.primary : Mac.card(context),
        border: Border.all(color: Mac.hairline(context), width: 0.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: Icon(
        back ? Icons.arrow_back_rounded : Icons.arrow_forward_rounded,
        size: 22,
        color: ready ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.35 + 0.65 * t),
      ),
    );
    return Positioned(
      left: back ? x : null,
      right: back ? null : x,
      top: 0,
      bottom: 0,
      child: IgnorePointer(child: Center(child: arrow)),
    );
  }
}

/// Reports the content navigator's pages, bottom first.
class _StackObserver extends NavigatorObserver {
  _StackObserver(this.onChange, {this.onPush});

  final void Function(List<Route<dynamic>> stack) onChange;
  final VoidCallback? onPush;
  final _stack = <Route<dynamic>>[];

  void _report() => onChange(List.of(_stack));

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    onPush?.call();
    _report();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _report();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (i >= 0 && newRoute != null) {
      _stack[i] = newRoute;
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
    _report();
  }
}

String _thousands(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

class _Folder {
  _Folder(this.tripId, this.name, this.path, this.cover, this.count);

  final int tripId;
  final String name;
  final String path;
  final String? cover;
  final int count;
}

/// The app's icon and name at the top of the sidebar.
class _Brand extends StatelessWidget {
  const _Brand({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.asset('assets/icon/app_icon_store_512.png', width: 24, height: 24, filterQuality: FilterQuality.medium),
    );
    return SizedBox(
      height: 40,
      child: wide
          ? Row(children: [
              const SizedBox(width: 6),
              logo,
              const SizedBox(width: 9),
              Text('ShareBro',
                  style: TextStyle(
                    fontFamily: Mac.fontDisplay,
                    fontFamilyFallback: Mac.fontFallback,
                    fontSize: TextSize.callout,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  )),
            ])
          : Center(child: logo),
    );
  }
}

/// A Mac search field: a rounded grey well with a magnifier, the
/// placeholder and the shortcut. Opens Search.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final faint = Mac.secondary(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
      child: Semantics(
        button: true,
        label: 'Search',
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: dark
                    ? Colors.white.withValues(alpha: _hover ? 0.12 : 0.08)
                    : Colors.black.withValues(alpha: _hover ? 0.08 : 0.055),
                borderRadius: BorderRadius.circular(Mac.controlRadius),
              ),
              child: Row(children: [
                Icon(Icons.search_rounded, size: 16, color: faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Search',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: TextSize.caption, color: faint)),
                ),
                Text('Ctrl K',
                    style: TextStyle(fontSize: TextSize.tiny, color: faint.withValues(alpha: 0.8), letterSpacing: 0.2)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Library", "Sharing": the small grey label over a group of rows, as in
/// Finder's sidebar. A short hairline in the rail.
class _Group extends StatelessWidget {
  const _Group(this.title, {required this.wide});

  final String title;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Divider(height: 0.5, thickness: 0.5, color: Mac.hairline(context)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: TextStyle(
            fontSize: TextSize.tiny,
            fontWeight: FontWeight.w600,
            color: Mac.secondary(context).withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

/// One sidebar row: an accent-tinted icon (or a folder's cover photo), the
/// label and a count or a live dot, on a rounded grey selection. Just the
/// icon in the rail.
class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.wide,
    required this.selected,
    required this.onTap,
    required this.tooltip,
    this.count,
    this.live = 0,
    this.cover,
    this.faint = false,
  });

  final IconData icon, selectedIcon;
  final String label;
  final bool wide, selected, faint;
  final VoidCallback onTap;
  final String tooltip;
  final String? count;

  /// Transfers going on: a pulsing green dot (with the number).
  final int live;

  /// A folder's cover photo instead of the icon.
  final String? cover;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = widget;
    final accent = scheme.primary;
    final secondary = Mac.secondary(context);
    final fg = w.faint ? secondary : scheme.onSurface;
    final iconColor = w.faint ? secondary : accent;
    final icon = w.cover != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(width: 18, height: 18, child: AssetThumb(id: w.cover!, size: 64)),
          )
        : Icon(w.selected ? w.selectedIcon : w.icon, size: w.wide ? 18 : 20, color: iconColor);
    final trailing = w.live > 0
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            const _LiveDot(),
            const SizedBox(width: 5),
            Text('${w.live}',
                style: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600, color: Mac.green)),
          ])
        : w.count == null
            ? null
            : Text(w.count!,
                style: TextStyle(
                  fontSize: TextSize.small,
                  color: secondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ));
    final fill = w.selected
        ? Mac.selection(context)
        : _down
            ? Mac.selection(context)
            : _hover
                ? Mac.hover(context)
                : Colors.transparent;
    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: w.wide ? 30 : 40,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: w.wide ? const EdgeInsets.symmetric(horizontal: 8) : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(w.wide ? Mac.rowRadius : Mac.controlRadius),
      ),
      child: w.wide
          ? Row(children: [
              SizedBox(width: 20, child: Center(child: icon)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TextSize.caption,
                    fontWeight: w.selected ? FontWeight.w600 : FontWeight.w400,
                    color: fg,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 6), trailing],
            ])
          : Center(
              child: Stack(clipBehavior: Clip.none, children: [
                icon,
                if (w.live > 0) const Positioned(right: -4, top: -3, child: _LiveDot()),
              ]),
            ),
    );
    return Tooltip(
      message: w.tooltip,
      waitDuration: Duration(milliseconds: w.wide ? 900 : 300),
      preferBelow: false,
      child: Semantics(
        button: true,
        selected: w.selected,
        label: w.label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _down = true),
            onTapUp: (_) => setState(() => _down = false),
            onTapCancel: () => setState(() => _down = false),
            onTap: w.onTap,
            child: row,
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _NavItem(
        icon: icon,
        selectedIcon: icon,
        label: tooltip,
        wide: false,
        selected: false,
        tooltip: tooltip,
        onTap: onTap,
      );
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: Mac.green,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Mac.green.withValues(alpha: 0.55 * (1 - _pulse.value)),
              spreadRadius: 6 * _pulse.value,
            ),
          ],
        ),
      ),
    );
  }
}

/// The running scan at the foot of the sidebar: the faces it has just
/// found, how far it's got, and Stop.
class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.controller, required this.onOpen});

  final ScanController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final faint = Mac.secondary(context);
    final eta = c.eta;
    final faces = c.recentFaces.reversed.take(5).toList().reversed.toList();
    final progress = c.total == 0 ? null : (c.done / c.total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Mac.card(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Mac.hairline(context), width: 0.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          mouseCursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(11, 9, 6, 11),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.face_retouching_natural_rounded, size: 16, color: scheme.primary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    c.upgrading ? 'Updating face matching' : 'Scanning ${c.albumName ?? 'photos'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: faint,
                    textStyle: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w500),
                  ),
                  onPressed: c.cancel,
                  child: const Text('Stop'),
                ),
              ]),
              if (faces.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(children: [
                  SizedBox(
                    height: 24,
                    width: 24 + 17.0 * (faces.length - 1),
                    child: Stack(children: [
                      for (final (i, f) in faces.indexed)
                        Positioned(left: 17.0 * i, child: _FaceDot(bytes: f, ring: Mac.card(context))),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text('${c.facesFound} ${c.facesFound == 1 ? 'face' : 'faces'}',
                      style: TextStyle(fontSize: TextSize.small, color: faint)),
                ]),
              ],
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: progress, minHeight: 4),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_thousands(c.done)} of ${_thousands(c.total)}'
                '${eta == null ? '' : ' · ${_eta(eta)}'}',
                style: TextStyle(fontSize: TextSize.tiny, color: faint, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

String _eta(Duration d) =>
    d.inMinutes >= 1 ? 'about ${d.inMinutes} min left' : 'less than a minute';

class _FaceDot extends StatelessWidget {
  const _FaceDot({required this.bytes, required this.ring});

  final Uint8List bytes;
  final Color ring;

  @override
  Widget build(BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 1.5)),
        child: ClipOval(child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)),
      );
}

/// The running scan in the rail: a progress ring.
class _ScanRing extends StatelessWidget {
  const _ScanRing({required this.controller, required this.onOpen});

  final ScanController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final progress = c.total == 0 ? null : (c.done / c.total).clamp(0.0, 1.0);
    return Tooltip(
      message: 'Scanning ${c.albumName ?? 'photos'} · ${c.done} of ${c.total}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onOpen,
          child: SizedBox(
            height: 46,
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: Stack(alignment: Alignment.center, children: [
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2.5,
                    backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
                  ),
                  Icon(Icons.face_retouching_natural_rounded, size: 15, color: scheme.primary),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// You, at the foot of the sidebar: opens Profile & settings.
class _Profile extends StatefulWidget {
  const _Profile({
    required this.wide,
    required this.thumb,
    required this.accent,
    required this.onTap,
    this.selected = false,
    this.update = false,
  });

  final bool wide;
  final Uint8List? thumb;
  final Color accent;
  final VoidCallback onTap;

  /// Settings is open.
  final bool selected;

  /// A new version is waiting: a small badge, and the subtitle says so.
  final bool update;

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final faint = Mac.secondary(context);
    final face = CircleAvatar(
      radius: 13,
      backgroundColor: widget.accent.withValues(alpha: 0.16),
      backgroundImage: widget.thumb == null ? null : FaceImage(widget.thumb!),
      child: widget.thumb == null ? Icon(Icons.person_rounded, size: 15, color: widget.accent) : null,
    );
    final avatar = !widget.update
        ? face
        : Stack(clipBehavior: Clip.none, children: [
            face,
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: widget.accent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Mac.sidebar(context), width: 2),
                ),
              ),
            ),
          ]);
    return Tooltip(
      message: 'Profile & settings  (Ctrl+,)',
      waitDuration: Duration(milliseconds: widget.wide ? 900 : 300),
      child: Semantics(
        button: true,
        label: 'Profile and settings',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 42,
              padding: EdgeInsets.symmetric(horizontal: widget.wide ? 6 : 0),
              decoration: BoxDecoration(
                color: widget.selected
                    ? Mac.selection(context)
                    : _hover
                        ? Mac.hover(context)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(Mac.controlRadius),
              ),
              child: widget.wide
                  ? Row(children: [
                      avatar,
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('You', style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
                              Text(widget.update ? 'Update available' : 'Profile & settings',
                                  style: TextStyle(
                                    fontSize: TextSize.tiny,
                                    color: widget.update ? widget.accent : faint,
                                    fontWeight: widget.update ? FontWeight.w600 : null,
                                  )),
                            ]),
                      ),
                      Icon(Icons.settings_outlined, size: 17, color: faint),
                      const SizedBox(width: 4),
                    ])
                  : Center(child: avatar),
            ),
          ),
        ),
      ),
    );
  }
}
