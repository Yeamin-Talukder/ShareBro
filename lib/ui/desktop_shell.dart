import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../scan/desktop_folders.dart';
import '../scan/scan_controller.dart';
import 'desktop_gallery.dart';
import 'desktop_layout.dart';
import 'group_screen.dart';
import 'scan_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// The pages the sidebar switches between. Folders get a page each.
enum DesktopPage { people, photos, explore, share, folder }

/// ShareBro's desktop window: a sidebar on the left (People, Photos,
/// Explore, sharing, the scanned folders, the running scan and settings)
/// and the page on the right. Below [DesktopLayout.wideFrom] the sidebar
/// folds into an icon rail. Replaces the phone's floating dock.
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

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.sharing.addListener(_sharingChanged);
    c.sharing.receiver.addListener(_sharingChanged);
    _load();
  }

  @override
  void dispose() {
    _reload?.cancel();
    c.removeListener(_changed);
    c.sharing.removeListener(_sharingChanged);
    c.sharing.receiver.removeListener(_sharingChanged);
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

  void _go(DesktopPage page, [_Folder? folder]) {
    setState(() => _folder = folder);
    widget.onPage(page);
  }

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
    _push(ScanScreen(controller: c));
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  void _search() => _push(SearchScreen(controller: c));

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
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search,
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _go(DesktopPage.people),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _go(DesktopPage.photos),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _go(DesktopPage.explore),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _go(DesktopPage.share),
      },
      child: Focus(
        autofocus: true,
        child: Row(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            width: wide ? DesktopLayout.sidebarWidth : DesktopLayout.railWidth,
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF141219) : const Color(0xFFEDEBF1),
              border: Border(
                right: BorderSide(color: dark ? const Color(0x12FFFFFF) : const Color(0x141A1820)),
              ),
            ),
            child: _sidebar(context, wide),
          ),
          Expanded(child: content),
        ]),
      ),
    );
  }

  Widget _sidebar(BuildContext context, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final sharing = c.sharing;
    final busy = sharing.activeCount + (sharing.receiver.session?.finished == false ? 1 : 0);
    final page = widget.page;
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
        padding: EdgeInsets.fromLTRB(wide ? 10 : 8, 10, wide ? 10 : 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _Brand(wide: wide),
          const SizedBox(height: 6),
          if (wide) _SearchField(onTap: _search) else _NavIcon(icon: Icons.search_rounded, tooltip: 'Search  (Ctrl+K)', onTap: _search),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
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
                selected: false,
                tooltip: 'Trip group',
                onTap: () => _push(TripGroupScreen(controller: c)),
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
          if (c.running)
            wide
                ? _ScanCard(controller: c, onOpen: () => _push(ScanScreen(controller: c)))
                : _ScanRing(controller: c, onOpen: () => _push(ScanScreen(controller: c))),
          const SizedBox(height: 4),
          _Profile(
            wide: wide,
            thumb: c.profile.thumb,
            accent: scheme.primary,
            onTap: () => _push(SettingsScreen(controller: c)),
          ),
        ]),
      ),
    );
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

class _Brand extends StatelessWidget {
  const _Brand({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.asset('assets/icon/app_icon_store_512.png', width: 28, height: 28, filterQuality: FilterQuality.medium),
    );
    return SizedBox(
      height: 44,
      child: wide
          ? Row(children: [
              const SizedBox(width: 8),
              logo,
              const SizedBox(width: 10),
              const Text('ShareBro', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ])
          : Center(child: logo),
    );
  }
}

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
    final faint = scheme.onSurface.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: _hover ? 0.9 : 0.6),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.onSurface.withValues(alpha: 0.07)),
            ),
            child: Row(children: [
              Icon(Icons.search_rounded, size: 18, color: faint),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Search people, places',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TextSize.caption, color: faint)),
              ),
              _Key('Ctrl+K'),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.12)),
      ),
      child: Text(text, style: TextStyle(fontSize: TextSize.tiny, color: scheme.onSurface.withValues(alpha: 0.55))),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title, {required this.wide});

  final String title;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
        child: Divider(height: 1, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: TextSize.tiny,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.9,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.42),
        ),
      ),
    );
  }
}

/// One sidebar row: icon (or a folder's cover photo), label and a count or
/// a live dot. Just the icon in the rail.
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
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final w = widget;
    final accent = scheme.primary;
    final fg = w.selected
        ? accent
        : _hover
            ? scheme.onSurface
            : scheme.onSurface.withValues(alpha: w.faint ? 0.45 : 0.68);
    final icon = w.cover != null
        ? ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(width: 22, height: 22, child: AssetThumb(id: w.cover!, size: 64)),
          )
        : Icon(w.selected ? w.selectedIcon : w.icon, size: 20, color: fg);
    final trailing = w.live > 0
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            const _LiveDot(),
            const SizedBox(width: 5),
            Text('${w.live}',
                style: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600, color: Color(0xFF30D158))),
          ])
        : w.count == null
            ? null
            : Text(w.count!,
                style: TextStyle(
                  fontSize: TextSize.small,
                  color: w.selected ? accent : scheme.onSurface.withValues(alpha: 0.42),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ));
    Widget row = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: w.wide ? const EdgeInsets.symmetric(horizontal: 11, vertical: 8) : const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: w.selected
            ? accent.withValues(alpha: 0.14)
            : _hover
                ? scheme.onSurface.withValues(alpha: 0.05)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: w.wide
          ? Row(children: [
              icon,
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  w.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: TextSize.label,
                    fontWeight: w.selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              ?trailing,
            ])
          : Center(
              child: Stack(clipBehavior: Clip.none, children: [
                icon,
                if (w.live > 0) const Positioned(right: -4, top: -3, child: _LiveDot()),
              ]),
            ),
    );
    if (w.wide && w.selected) {
      // The accent bar on the left edge of the selected row.
      row = Stack(children: [
        row,
        Positioned(
          left: 0,
          top: 10,
          bottom: 10,
          child: Container(width: 3, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(3))),
        ),
      ]);
    }
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
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: w.onTap, child: row),
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
    const green = Color(0xFF30D158);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: green,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: green.withValues(alpha: 0.6 * (1 - _pulse.value)),
              spreadRadius: 7 * _pulse.value,
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
    final faint = scheme.onSurface.withValues(alpha: 0.45);
    final eta = c.eta;
    final faces = c.recentFaces.reversed.take(5).toList().reversed.toList();
    final progress = c.total == 0 ? null : (c.done / c.total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.face_retouching_natural_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.upgrading ? 'Updating face matching' : 'Scanning ${c.albumName ?? 'photos'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: faint,
                    textStyle: const TextStyle(fontSize: TextSize.small),
                  ),
                  onPressed: c.cancel,
                  child: const Text('Stop'),
                ),
              ]),
              if (faces.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(children: [
                  SizedBox(
                    height: 28,
                    width: 28 + 21.0 * (faces.length - 1),
                    child: Stack(children: [
                      for (final (i, f) in faces.indexed)
                        Positioned(left: 21.0 * i, child: _FaceDot(bytes: f, ring: scheme.surfaceContainerHighest)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text('${c.facesFound} ${c.facesFound == 1 ? 'face' : 'faces'}', style: TextStyle(fontSize: TextSize.small, color: faint)),
                ]),
              ],
              const SizedBox(height: 8),
              Text(
                '${c.done} of ${c.total} photos'
                '${eta == null ? '' : ' · ${_eta(eta)}'}',
                style: TextStyle(fontSize: TextSize.small, color: faint),
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                ),
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
        width: 28,
        height: 28,
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
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
      child: InkResponse(
        onTap: onOpen,
        radius: 24,
        child: SizedBox(
          height: 48,
          child: Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: Stack(alignment: Alignment.center, children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 3,
                  backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                ),
                Icon(Icons.face_retouching_natural_rounded, size: 17, color: scheme.primary),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Profile extends StatefulWidget {
  const _Profile({required this.wide, required this.thumb, required this.accent, required this.onTap});

  final bool wide;
  final Uint8List? thumb;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = CircleAvatar(
      radius: 14,
      backgroundColor: widget.accent.withValues(alpha: 0.18),
      backgroundImage: widget.thumb == null ? null : MemoryImage(widget.thumb!),
      child: widget.thumb == null ? Icon(Icons.person_rounded, size: 16, color: widget.accent) : null,
    );
    return Tooltip(
      message: 'Profile & settings',
      waitDuration: Duration(milliseconds: widget.wide ? 900 : 300),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(horizontal: widget.wide ? 10 : 0, vertical: 8),
            decoration: BoxDecoration(
              color: _hover ? scheme.onSurface.withValues(alpha: 0.05) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: widget.wide
                ? Row(children: [
                    avatar,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('You', style: TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
                        Text('Profile & settings',
                            style: TextStyle(fontSize: TextSize.small, color: scheme.onSurface.withValues(alpha: 0.45))),
                      ]),
                    ),
                    Icon(Icons.settings_outlined, size: 20, color: scheme.onSurface.withValues(alpha: 0.45)),
                  ])
                : Center(child: avatar),
          ),
        ),
      ),
    );
  }
}

