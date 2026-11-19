import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anim.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../platform/device.dart';
import '../scan/scan_controller.dart';
import '../share/native_files.dart';
import '../share/net.dart';
import '../share/prepare.dart';
import '../share/protocol.dart';
import '../share/receive.dart';
import '../share/send_center.dart' show JobStatus;
import 'active_shares.dart';
import 'app_picker.dart';
import 'desktop_layout.dart';
import 'devices.dart';
import 'file_icons.dart';
import 'find_me_screen.dart';
import 'gallery_view.dart';
import 'group_screen.dart';
import 'glass.dart';
import 'motion.dart';
import 'permission_explainer.dart';
import 'photo_viewer.dart';
import 'receive_screen.dart';
import 'send_center_screen.dart';
import 'sections.dart';
import 'send_to_sheet.dart';
import 'theme.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';
import 'widgets.dart';

/// LocalSend-style sharing for anything: Receive (be findable, quick save,
/// PIN) and Send (pick photos, files, a folder or text, then tap a nearby
/// device), plus the history of everything sent and received.
class ShareTab extends StatefulWidget {
  const ShareTab({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ShareTab> createState() => _ShareTabState();
}

class _ShareTabState extends State<ShareTab> {
  bool _receive = false;
  final List<SendItem> _items = [];

  /// Desktop: files are being dragged over the window.
  bool _dropping = false;

  /// Desktop: files and folders dropped on the page join what's picked
  /// (and the page turns to Send if it was on Receive).
  Future<void> _dropped(DropDoneDetails d) async {
    setState(() {
      _dropping = false;
      _receive = false;
    });
    final items = <SendItem>[];
    for (final f in d.files) {
      final path = f.path;
      if (path.isEmpty) continue;
      if (await FileSystemEntity.isDirectory(path)) {
        items.addAll(await SendItem.folder(path));
      } else {
        items.add(SendItem.file(path, name: p.basename(path)));
      }
    }
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nothing to send in what was dropped.')));
      return;
    }
    _add(items);
  }

  ScanController get c => widget.controller;

  void _add(Iterable<SendItem> items) {
    if (items.isEmpty) return;
    Haptics.tick();
    setState(() {
      for (final i in items) {
        final dupe = _items.any((x) =>
            (i.assetId != null && x.assetId == i.assetId) || (i.path != null && x.path == i.path && x.name == i.name));
        if (!dupe) _items.add(i);
      }
    });
  }

  Future<void> _pickMedia() async {
    if (!await ensurePhotoAccess(context) || !mounted) return;
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Pick photos & videos')),
          body: GalleryView(
            controller: c,
            source: GallerySource.everything(c, media: true),
            onPicked: (ids) => Navigator.pop(context, ids),
          ),
        ),
      ),
    );
    if (ids != null) _add(ids.map(SendItem.asset));
  }

  Future<void> _pickApps() async {
    final items = await Navigator.push<List<SendItem>>(
        context, MaterialPageRoute(builder: (_) => const AppPickerScreen()));
    if (items != null) _add(items);
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(dialogTitle: 'Choose files to send');
    _add([for (final f in files) if (f.path != null) SendItem.file(f.path!, name: f.name)]);
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder to send');
    if (dir == null) return;
    final items = await SendItem.folder(dir);
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That folder looks empty.')));
    }
    _add(items);
  }

  Future<void> _writeText({String? initial}) async {
    final ctrl = TextEditingController(text: initial);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send a message'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: 'A link, an address, a note…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Add')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) _add([SendItem.text(text.trim())]);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The clipboard is empty.')));
      return;
    }
    _add([SendItem.text(text)]);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page(context);
    if (!DesktopLayout.on) return page;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: _dropped,
      child: Stack(children: [
        page,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _dropping ? 1 : 0,
              duration: 150.ms,
              child: const _DropOverlay(),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _page(BuildContext context) {
    final s = c.sharing;
    final desk = DesktopLayout.on;
    return GlassScrollView(
      title: 'Share',
      actions: [
        // Desktop: Send / Receive sits in the toolbar, like the demo.
        if (desk) ...[
          SizedBox(
            width: 200,
            child: CapsuleSwitch<bool>(
              value: _receive,
              height: 36,
              options: const [(false, 'Send', null), (true, 'Receive', null)],
              onChanged: (v) => setState(() => _receive = v),
            ),
          ),
          const SizedBox(width: 8),
        ],
        ToolbarCapsule(children: [
              ListenableBuilder(
                listenable: s,
                builder: (context, _) => IconButton(
                  tooltip: 'Sending',
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => SendCenterScreen(controller: c))),
                  icon: Badge(
                    isLabelVisible: s.activeCount > 0,
                    label: Text('${s.activeCount}'),
                    child: const Icon(Icons.outbox_rounded),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'History',
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => TransferHistoryScreen(controller: c))),
                icon: const Icon(Icons.history_rounded),
              ),
        ]),
      ],
      slivers: [
        // Desktop: links, sends and receives going on now, each with Stop.
        if (desk)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverToBoxAdapter(child: SharingNowSection(controller: c)),
          ),
        if (desk)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(24, 4, 24, MediaQuery.paddingOf(context).bottom + 24),
            sliver: SliverToBoxAdapter(
              child: LayoutBuilder(
                builder: (context, box) => AnimatedSwitcher(
                  duration: 320.ms,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _receive
                      // Wide: two columns like Send; narrow: one centred column.
                      ? box.maxWidth >= DesktopLayout.twoColumnsFrom
                          ? _ReceivePanel(key: const ValueKey('receive'), controller: c, wide: true)
                          : Center(
                              key: const ValueKey('receive'),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 720),
                                child: _ReceivePanel(controller: c),
                              ),
                            )
                      : box.maxWidth >= DesktopLayout.twoColumnsFrom
                          ? _deskSend(context)
                          : _sendPanel(context),
                ),
              ),
            ),
          )
        else
        SliverPadding(
          // Clear the floating nav bar so the last buttons stay reachable.
          padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.paddingOf(context).bottom + 24),
          sliver: SliverList.list(children: [
            // Links, sends and receives going on now, each with Stop.
            SharingNowSection(controller: c),
            CapsuleSwitch<bool>(
              value: _receive,
              options: const [(false, 'Send', null), (true, 'Receive', null)],
              onChanged: (v) => setState(() => _receive = v),
            ),
            AnimatedSwitcher(
              duration: 320.ms,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a),
                  child: child,
                ),
              ),
              child: _receive
                  ? _ReceivePanel(key: const ValueKey('receive'), controller: c)
                  : _sendPanel(context),
            ),
          ]),
        ),
      ],
    );
  }

  /// Desktop, wide: what to send and how on the left; nearby devices and
  /// what's being sent or received on the right.
  Widget _deskSend(BuildContext context) {
    final picked = _items.isEmpty ? null : describeItems(_items);
    return Row(key: const ValueKey('send-desk'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        flex: 10,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 8),
          _Step(
            number: 1,
            title: 'Choose what to send',
            done: _items.isNotEmpty,
            subtitle: picked == null ? 'Drop files here, or pick them' : '${picked[0].toUpperCase()}${picked.substring(1)} ready',
          ),
          _deskPickCard(context),
          const SizedBox(height: 22),
          const SectionHeader(title: 'More ways to share', top: 0),
          _optionsCard(context),
          const SectionFooter(
            'Works with the free LocalSend app on Android, iPhone, Windows, Mac and Linux on the same Wi‑Fi or hotspot. '
            'The link works in any browser.',
          ),
        ]),
      ),
      const SizedBox(width: 20),
      Expanded(
        flex: 11,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 8),
          _Step(
            number: 2,
            title: 'Pick a device',
            subtitle: _items.isEmpty
                ? 'Devices on this Wi‑Fi show up here'
                : 'Click a device to send ${describeItems(_items)}',
          ),
          _devicePicker(context),
          const SizedBox(height: 20),
          _ActivityCard(controller: c),
        ]),
      ),
    ]);
  }

  /// Desktop: what to send. Empty, a drop zone with the pick buttons in it;
  /// with things picked, those things and buttons to add more.
  Widget _deskPickCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget buttons({bool compact = false}) =>
        Wrap(spacing: compact ? 6 : 10, runSpacing: compact ? 6 : 10, alignment: WrapAlignment.center, children: [
          _AddTile(
              icon: Icons.photo_library_rounded, color: const Color(0xFFFF9500), label: 'Photos', compact: compact, onTap: _pickMedia),
          _AddTile(
              icon: Icons.description_rounded, color: const Color(0xFF0A84FF), label: 'Files', compact: compact, onTap: _pickFiles),
          _AddTile(icon: Icons.folder_rounded, color: const Color(0xFF30B0C7), label: 'Folder', compact: compact, onTap: _pickFolder),
          _AddTile(icon: Icons.notes_rounded, color: const Color(0xFF34C759), label: 'Text', compact: compact, onTap: _writeText),
          _AddTile(
              icon: Icons.content_paste_rounded, color: const Color(0xFFAF52DE), label: 'Paste', compact: compact, onTap: _paste),
        ]);
    if (_items.isEmpty) {
      return SectionCard(
        padding: const EdgeInsets.all(14),
        child: CustomPaint(
          painter: _DashedBorder(scheme.onSurfaceVariant.withValues(alpha: _dropping ? 0.8 : 0.3)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.file_download_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text('Drop photos, files or folders here',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 3),
              Text('or pick what to send',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 18),
              buttons(),
            ]),
          ),
        ),
      );
    }
    final picked = describeItems(_items);
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text('${picked[0].toUpperCase()}${picked.substring(1)}',
                style: const TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () {
              Haptics.remove();
              setState(_items.clear);
            },
            child: const Text('Clear all'),
          ),
        ]),
        const SizedBox(height: 4),
        ItemStrip(items: List.of(_items), onRemove: (i) => setState(() => _items.remove(i)), height: 72),
        const SizedBox(height: 12),
        Row(children: [
          Text('Add more', style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: buttons(compact: true))),
        ]),
      ]),
    );
  }

  Widget _devicePicker(BuildContext context) => DevicePicker(
        sharing: c.sharing,
        count: _items.length,
        onPick: (t) async {
          final items = List.of(_items);
          setState(_items.clear);
          // Progress shows on the device in the orbit; tap it to open the send.
          await sendItemsTo(context, c, t, items, open: false);
        },
        onOpenJob: (job) =>
            Navigator.push(context, MaterialPageRoute(builder: (_) => TransferScreen(controller: c, job: job))),
      );

  Widget _sendPanel(BuildContext context) {
    return Column(key: const ValueKey('send'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 18),
      if (DesktopLayout.on) ...[_deskPickCard(context), const SizedBox(height: 12)] else _pickCard(context),
      _devicePicker(context),
      const SizedBox(height: 22),
      _optionsCard(context),
      const SectionFooter(
        'Works with the free LocalSend app on Android, iPhone, Windows, Mac and Linux on the same Wi‑Fi or hotspot, '
        'and with ShareBro phones over Nearby, no Wi‑Fi needed. The link works in any browser.',
      ),
    ]);
  }

  /// The pick buttons and, below them, what's picked. With [hint] and
  /// nothing picked yet, a dashed row says what can be added.
  Widget _pickCard(BuildContext context, {bool hint = false}) {
    final picked = describeItems(_items);
    final scheme = Theme.of(context).colorScheme;
    return SectionCard(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 14),
            child: Row(children: [
              if (Device.photoLibrary || Device.desktop)
                _PickButton(icon: Icons.photo_library_outlined, label: Device.desktop ? 'Photos' : 'Media', onTap: _pickMedia),
              _PickButton(icon: Icons.insert_drive_file_outlined, label: 'Files', onTap: _pickFiles),
              _PickButton(icon: Icons.folder_outlined, label: 'Folder', onTap: _pickFolder),
              _PickButton(icon: Icons.notes_rounded, label: 'Text', onTap: _writeText),
              _PickButton(icon: Icons.content_paste_rounded, label: 'Paste', onTap: _paste),
              if (Device.installedApps) _PickButton(icon: Icons.apps_rounded, label: 'Apps', onTap: _pickApps),
            ]),
          ),
          // What's picked appears in the same card, ready to send.
          AnimatedSize(
            duration: 300.ms,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _items.isEmpty
                ? (hint
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        child: _DashedHint(
                          icon: Icons.file_upload_outlined,
                          title: 'Add photos, files or a folder',
                          subtitle: 'Pick them with the buttons above, then choose a device',
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    : const SizedBox(width: double.infinity))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Divider(height: 0.5, thickness: 0.5),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 8, 14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text('${picked[0].toUpperCase()}${picked.substring(1)}',
                              style: const TextStyle(fontSize: TextSize.body, fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              Haptics.remove();
                              setState(_items.clear);
                            },
                            child: const Text('Clear'),
                          ),
                        ]),
                        ItemStrip(items: List.of(_items), onRemove: (i) => setState(() => _items.remove(i)), height: 64),
                      ]),
                    ),
                  ]),
          ),
        ]),
      );
  }

  /// Link or QR code, other apps, trip group and Find my photos.
  Widget _optionsCard(BuildContext context) {
    return SectionCard.rows(rows: [
        SectionRow(
          leading: const IconTile(icon: Icons.qr_code_2_rounded, color: Color(0xFF5E5CE6)),
          title: 'Link or QR code',
          subtitle: 'Opens in any browser',
          chevron: true,
          enabled: _items.isNotEmpty,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => WebShareScreen(controller: c, title: 'Shared with ShareBro', items: List.of(_items)),
            ),
          ),
        ),
        SectionRow(
          leading: const IconTile(icon: Icons.ios_share_rounded, color: Color(0xFF0A84FF)),
          title: 'Other apps',
          subtitle: 'Quick Share, WhatsApp and more',
          chevron: true,
          enabled: _items.isNotEmpty,
          onTap: () => shareItemsWithApps(List.of(_items)),
        ),
        // Both match faces in the scanned photos.
        if (Device.photoLibrary || Device.desktop) ...[
        SectionRow(
          leading: const IconTile(icon: Icons.diversity_3_rounded, color: Color(0xFF30D158)),
          title: 'Trip group',
          subtitle: c.sharing.groups.group == null
              ? 'Everyone gets the photos they\'re in'
              : 'In ${c.sharing.groups.group!.name}',
          chevron: true,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => TripGroupScreen(controller: c)),
          ),
        ),
        SectionRow(
          leading: const IconTile(icon: Icons.face_retouching_natural_rounded, color: Color(0xFFFF9F0A)),
          title: 'Find my photos',
          subtitle: 'Friends take a selfie and get the photos they\'re in',
          chevron: true,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => FindMeScreen(controller: c)),
          ),
        ),
        ],
      ]);
  }
}

/// Desktop Share: a numbered step ("1 Choose what to send") with a line
/// saying where it stands; the number turns into a tick once it's done.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title, required this.subtitle, this.done = false});

  final int number;
  final String title, subtitle;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 10),
      child: Row(children: [
        AnimatedContainer(
          duration: 200.ms,
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done ? const Color(0xFF34C759) : scheme.primary,
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                : Text('$number',
                    style: TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w700, color: scheme.onPrimary)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

/// Desktop: one kind of thing to send (Photos, Files, Folder…), as a tile
/// with its own coloured icon; [compact] is a small chip for "Add more".
class _AddTile extends StatefulWidget {
  const _AddTile({required this.icon, required this.color, required this.label, required this.onTap, this.compact = false});

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_AddTile> createState() => _AddTileState();
}

class _AddTileState extends State<_AddTile> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final scheme = Theme.of(context).colorScheme;
    final glyph = Container(
      width: w.compact ? 20 : 38,
      height: w.compact ? 20 : 38,
      decoration: BoxDecoration(color: w.color, borderRadius: BorderRadius.circular(w.compact ? 5 : 10)),
      child: Icon(w.icon, size: w.compact ? 13 : 21, color: Colors.white),
    );
    final body = w.compact
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            glyph,
            const SizedBox(width: 7),
            Text(w.label, style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w500)),
          ])
        : Column(mainAxisSize: MainAxisSize.min, children: [
            glyph,
            const SizedBox(height: 7),
            Text(w.label, style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w500)),
          ]);
    return Semantics(
      button: true,
      label: w.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          onTap: w.onTap,
          child: AnimatedScale(
            scale: _down ? 0.96 : 1,
            duration: const Duration(milliseconds: 100),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: w.compact ? null : 92,
              padding: w.compact ? const EdgeInsets.fromLTRB(6, 5, 10, 5) : const EdgeInsets.fromLTRB(6, 12, 6, 10),
              decoration: BoxDecoration(
                color: _hover ? Mac.hover(context) : scheme.onSurface.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(w.compact ? 8 : 12),
                border: Border.all(color: _hover ? w.color.withValues(alpha: 0.5) : Mac.hairline(context), width: 0.8),
              ),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop: what the page looks like while files are dragged over it.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface.withValues(alpha: 0.82),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: CustomPaint(
          painter: _DashedBorder(scheme.primary, width: 2.5, radius: 18),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                child: Icon(Icons.file_download_outlined, size: 36, color: scheme.onPrimary),
              ),
              const SizedBox(height: 16),
              const Text('Drop to send', style: TextStyle(fontSize: TextSize.title2, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Photos, files and whole folders',
                  style: TextStyle(fontSize: TextSize.label, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A dashed, rounded box with an icon and two lines: what can be added
/// (desktop Share's empty pick card).
class _DashedHint extends StatelessWidget {
  const _DashedHint({required this.icon, required this.title, required this.subtitle, required this.color});

  final IconData icon;
  final String title, subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorder(color.withValues(alpha: 0.35)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w600)),
              Text(subtitle, style: TextStyle(fontSize: TextSize.small, color: color)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  _DashedBorder(this.color, {this.width = 1.5, this.radius = 14});

  final Color color;
  final double width, radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color || old.width != width || old.radius != radius;
}

/// Desktop Share: what's being received and sent right now, and the last
/// few transfers, with "All transfers" for the rest.
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.controller});

  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.sharing;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.receiver]),
      builder: (context, _) {
        final rows = <Widget>[];
        final r = s.receiver.session;
        if (r != null && !r.cancelled) {
          final total = r.tokens.length, got = r.done.length;
          final files = '$got of $total ${total == 1 ? 'file' : 'files'}';
          rows.add(_ActivityRow(
            icon: Icons.south_west_rounded,
            color: const Color(0xFF30D158),
            title: r.finished ? 'Received from ${r.from}' : 'Receiving from ${r.from}',
            subtitle: r.finished ? '$files · ${formatTime(r.started)}' : '$files · saving to Downloads\\ShareBro',
            progress: r.finished || r.totalBytes == 0 ? null : (r.bytes / r.totalBytes).clamp(0.0, 1.0),
            done: r.finished,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiveScreen(controller: controller))),
          ));
        }
        for (final j in s.jobs.reversed.take(4)) {
          final n = '${j.count} ${j.noun}';
          rows.add(_ActivityRow(
            icon: Icons.north_east_rounded,
            color: scheme.primary,
            title: switch (j.status) {
              JobStatus.done => 'Sent $n to ${j.deviceAlias}',
              JobStatus.failed || JobStatus.declined || JobStatus.needsPin => 'Not sent to ${j.deviceAlias}',
              JobStatus.cancelled => 'Stopped sending to ${j.deviceAlias}',
              _ => 'Sending $n to ${j.deviceAlias}',
            },
            subtitle: switch (j.status) {
              JobStatus.done || JobStatus.cancelled => j.personName,
              JobStatus.declined => 'They said no',
              JobStatus.needsPin => 'Needs their PIN',
              JobStatus.failed => j.message ?? 'Something went wrong',
              JobStatus.waiting => 'Waiting for the device',
              JobStatus.asking => 'Waiting for them to accept',
              JobStatus.preparing => 'Getting the files ready',
              JobStatus.sending => '${j.filesDone} of ${j.count} sent',
            },
            progress: j.active ? j.progress : null,
            done: j.status == JobStatus.done,
            failed: j.canRetry,
            onTap: () =>
                Navigator.push(context, MaterialPageRoute(builder: (_) => TransferScreen(controller: controller, job: j))),
          ));
        }
        return SectionCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Text('Activity', style: TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => SendCenterScreen(controller: controller))),
                  child: const Text('All transfers'),
                ),
              ]),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 2, 8, 10),
                  child: Text('Nothing sent or received yet. Transfers show up here as they happen.',
                      style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
                )
              else
                for (final (i, row) in rows.indexed) ...[
                  if (i > 0) Divider(height: 1, thickness: 0.5, color: scheme.outlineVariant),
                  row,
                ],
            ]),
          ),
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.progress,
    this.done = false,
    this.failed = false,
  });

  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;

  /// 0..1 while under way; null when finished or waiting.
  final double? progress;
  final bool done, failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(Mac.controlRadius),
      mouseCursor: SystemMouseCursors.click,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          IconTile(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w600)),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
              if (progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: progress, minHeight: 5),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 8),
          if (done)
            const Icon(Icons.check_circle_rounded, color: Color(0xFF30D158), size: 22)
          else if (failed)
            Icon(Icons.error_outline_rounded, color: scheme.error, size: 22)
          else
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Pressable(
        onTap: onTap,
        scale: 0.9,
        child: Column(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: capsuleFill(context),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, size: 23, color: scheme.onSurface),
          ),
          const SizedBox(height: 7),
          Text(label, style: TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Being findable: you in the middle of the orbit, on/off, quick save and
/// PIN, the transfer in progress and what arrived lately.
class _ReceivePanel extends StatefulWidget {
  const _ReceivePanel({super.key, required this.controller, this.wide = false});

  final ScanController controller;

  /// Desktop, wide window: two columns that fit one screen, like Send.
  final bool wide;

  @override
  State<_ReceivePanel> createState() => _ReceivePanelState();
}

class _ReceivePanelState extends State<_ReceivePanel> {
  String? _ip;
  AppDb get _db => widget.controller.db;
  late Future<List<Transfer>> _recent = _db.transfers(limit: 3);

  @override
  void initState() {
    super.initState();
    localIp().then((ip) {
      if (mounted) setState(() => _ip = ip);
    });
    _db.transfersChanged.addListener(_reload);
  }

  @override
  void dispose() {
    _db.transfersChanged.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _recent = _db.transfers(limit: 3));
  }

  void _openLive() =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReceiveLiveScreen(controller: widget.controller)));

  void _openHistory() =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => TransferHistoryScreen(controller: widget.controller)));

  Future<void> _editPin(Receiver r) async {
    final ctrl = TextEditingController(text: r.pin ?? (1000 + math.Random.secure().nextInt(9000)).toString());
    final pin = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Senders type this code before anything arrives.'),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(hintText: '4 to 6 digits'),
          ),
        ]),
        actions: [
          if (r.pin != null) TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Turn off')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (pin == null) return;
    await r.setPin(pin.isEmpty ? null : pin);
  }

  static double _progress(ReceiveSession x) {
    final total = x.totalBytes;
    return x.finished ? 1 : total == 0 ? 0 : x.bytes / total;
  }

  OrbitNode _sender(ReceiveSession x) {
    final p = _progress(x);
    return OrbitNode(
      key: 'incoming',
      name: x.from,
      subtitle: x.finished ? 'Sent to you' : 'Sending ${(p * 100).round()}%',
      icon: Icons.devices_rounded,
      color: deviceColor(x.from),
      angle: 50,
      progress: x.finished ? null : p,
      done: x.finished,
      status: true,
      flowing: !x.finished,
    );
  }

  /// Your orb: grey while off, glowing while ready, filling up as files
  /// arrive.
  Widget _inbox(ReceiveSession? x, bool on) {
    if (x != null) {
      final p = _progress(x);
      return OrbitTank(
        progress: p,
        child: x.finished ? const Icon(Icons.check_rounded, size: 36) : Text('${(p * 100).round()}%'),
      );
    }
    return OrbitCore(size: 96, idle: !on, child: const Icon(Icons.download_rounded, size: 34));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.sharing;
    final r = s.receiver;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s, r]),
      builder: (context, _) {
        final session = r.session;
        final on = r.enabled;
        Future<void> toggle() async {
          Haptics.tick();
          if (!on) await ensureNearbyAccess(context, s.nearby, quiet: true);
          await s.setReceiving(!on);
        }

        final wide = widget.wide;
        final inbox = SectionCard(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(children: [
              Orbit(
                height: wide ? 250 : 300,
                centreY: wide ? 125 : 150,
                centreSize: 96,
                scanning: on,
                inflow: true,
                nodes: [if (session != null) _sender(session)],
                centre: _inbox(session, on),
                onCentreTap: session == null ? null : _openLive,
                onTap: (_, _) => _openLive(),
              ),
              Text(s.identity.alias, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              AnimatedSwitcher(
                duration: 250.ms,
                child: Row(key: ValueKey(on), mainAxisSize: MainAxisSize.min, children: [
                  if (on) ...[const _LiveDot(), const SizedBox(width: 7)],
                  Text(on ? 'Visible to nearby devices' : 'Receiving is off',
                      style: TextStyle(fontSize: TextSize.callout, color: scheme.onSurfaceVariant)),
                ]),
              ),
              const SizedBox(height: 3),
              Text('${_ip ?? 'No network'} · port $lsPort',
                  style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              on
                  ? FilledButton.tonal(
                      style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
                      onPressed: toggle,
                      child: const Text('Stop receiving'),
                    )
                  : FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
                      onPressed: toggle,
                      child: const Text('Start receiving'),
                    ),
            ]),
          );
        final live = session == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 14),
                child: _LiveSession(session: session, onTap: _openLive),
              ).animate().fadeIn().moveY(begin: 8);
        final options = SectionCard.rows(rows: [
            SectionRow(
              leading: const IconTile(icon: Icons.bolt_rounded, color: Color(0xFFFF9F0A)),
              title: 'Quick save',
              trailing: Switch(value: r.quickSave, onChanged: r.setQuickSave),
              onTap: () => r.setQuickSave(!r.quickSave),
            ),
            SectionRow(
              leading: const IconTile(icon: Icons.star_rounded, color: Color(0xFFFFCC00), iconColor: Color(0xFF3D2E00)),
              title: 'Auto-accept favourites',
              enabled: !r.quickSave,
              trailing: Switch(value: r.autoAcceptPaired, onChanged: r.quickSave ? null : r.setAutoAccept),
              onTap: () => r.setAutoAccept(!r.autoAcceptPaired),
            ),
            SectionRow(
              leading: const IconTile(icon: Icons.lock_rounded, color: Color(0xFF8E8E93)),
              title: 'PIN',
              trailing: Text(r.pin ?? 'Off', style: TextStyle(fontSize: TextSize.body, color: scheme.onSurfaceVariant)),
              chevron: true,
              onTap: () => _editPin(r),
            ),
          ]);
        final optionsNote = SectionFooter(r.quickSave
              ? 'Everything is saved without asking.'
              : 'You\'re asked before anything is saved. Favourites and paired phones skip the question.');
        final recent = FutureBuilder<List<Transfer>>(
            future: _recent,
            builder: (context, snap) {
              final list = snap.data ?? const <Transfer>[];
              if (list.isEmpty) return const SizedBox.shrink();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SectionHeader(
                  title: 'Recent',
                  trailing: TextButton(onPressed: _openHistory, child: const Text('See all')),
                ),
                SectionCard.rows(rows: [
                  for (final t in list)
                    SectionRow(
                      leading: FileBadge(mime: t.mime, name: t.fileName, size: 32),
                      title: t.isText ? t.text! : t.fileName,
                      subtitle: '${t.incoming ? 'From' : 'To'} ${t.peer} · ${formatTime(t.at)}'
                          '${t.isText ? '' : ' · ${formatBytes(t.size)}'}',
                      trailing: Icon(t.incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
                          size: 18, color: scheme.onSurfaceVariant),
                      onTap: _openHistory,
                    ),
                ]),
              ]);
            },
          );
        final where = SectionFooter(DesktopLayout.on
            ? 'Everything is saved to Downloads\\$receivedAlbum, and photos are scanned for faces. '
                'Messages pop up so you can copy them. Receiving works while ShareBro is open.'
            : 'Photos and videos go to the "$receivedAlbum" album and are scanned for faces; other files go to '
                'Download/$receivedAlbum; messages pop up so you can copy them. Receiving keeps working in the background.');

        if (wide) {
          // Two columns like Send: being visible on the left, how files
          // arrive (and what arrived) on the right.
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 11,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 8),
                _Step(
                  number: 1,
                  title: 'Be visible',
                  done: on,
                  subtitle: on ? 'Nearby devices can send to "${s.identity.alias}"' : 'Turn on so others can send to you',
                ),
                inbox,
                ?live,
              ]),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 10,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SizedBox(height: 8),
                _Step(
                  number: 2,
                  title: 'Choose how files arrive',
                  subtitle: r.quickSave ? 'Saved straight away, without asking' : 'You approve each transfer first',
                ),
                options,
                optionsNote,
                recent,
                where,
              ]),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 18),
          inbox,
          ?live,
          const SectionHeader(title: 'Options'),
          options,
          optionsNote,
          recent,
          where,
        ]);
      },
    );
  }
}

/// A softly pulsing green dot: "on and visible".
class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(color: Color(0xFF30D158), shape: BoxShape.circle),
    );
    if (MediaQuery.disableAnimationsOf(context)) return dot;
    return dot
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .fade(begin: 1, end: 0.35, duration: 900.ms, curve: Curves.easeInOut);
  }
}

class _LiveSession extends StatelessWidget {
  const _LiveSession({required this.session, required this.onTap});

  final ReceiveSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = session.totalBytes;
    final from = session.from;
    final initials = from.split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join().toUpperCase();
    final card = SectionCard(
      child: Column(children: [
        SectionRow(
          leading: CircleAvatar(
            radius: 16,
            backgroundColor: deviceColor(from),
            child: Text(initials, style: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          title: session.finished ? 'Got ${session.done.length} from $from' : 'Receiving from $from',
          subtitle: '${session.done.length} of ${session.tokens.length} · ${formatBytes(session.bytes)} of ${formatBytes(total)}',
          trailing: session.finished
              ? Icon(Icons.check_circle_rounded, size: 28, color: scheme.primary)
              : SizedBox.square(
                  dimension: 28,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: total == 0 ? 0 : session.bytes / total),
                    duration: 300.ms,
                    builder: (context, v, _) => CircularProgressIndicator(
                      value: v,
                      strokeWidth: 3,
                      strokeCap: StrokeCap.round,
                      backgroundColor: scheme.onSurface.withAlpha(30),
                    ),
                  ),
                ),
          chevron: true,
          onTap: onTap,
        ),
        if (session.savedIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(62, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final id in session.savedIds.take(14))
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox.square(dimension: 22, child: AssetThumb(id: id, size: 80)),
                  ),
              ]),
            ),
          ),
      ]),
    );
    // A shimmer sweeps across once everything has arrived.
    return card
        .animate(target: session.finished ? 1 : 0)
        .shimmer(duration: 900.ms, color: Colors.white.withValues(alpha: 0.5));
  }
}

/// Everything sent and received, newest first. Tap to open; swipe to remove.
class TransferHistoryScreen extends StatefulWidget {
  const TransferHistoryScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<TransferHistoryScreen> createState() => _TransferHistoryScreenState();
}

class _TransferHistoryScreenState extends State<TransferHistoryScreen> {
  AppDb get db => widget.controller.db;
  late Future<List<Transfer>> _list = db.transfers();
  int _filter = 0; // 0 all, 1 received, 2 sent

  @override
  void initState() {
    super.initState();
    db.transfersChanged.addListener(_reload);
  }

  @override
  void dispose() {
    db.transfersChanged.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _list = db.transfers());
  }

  Future<void> _open(Transfer t) async {
    if (t.isText) {
      await showMessageDialog(context, from: t.incoming ? t.peer : 'you to ${t.peer}', text: t.text!);
      return;
    }
    final loc = t.location;
    if (loc == null || loc.isEmpty) return;
    // Gallery items are stored by id; files by their path or content:// URI.
    if (!loc.contains('/') && !loc.contains(':')) {
      if (!mounted) return;
      await Navigator.push(
        context,
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, a, _) => FadeTransition(
            opacity: a,
            child: PhotoViewer(ids: [loc], initial: 0, controller: widget.controller),
          ),
        ),
      );
      return;
    }
    final ok = await NativeFiles.open(loc, mime: t.mime);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Couldn\'t open it — it may have been moved or deleted.')));
    }
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('Only the list is cleared; received files stay where they were saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (yes ?? false) await db.clearTransfers();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [IconButton(tooltip: 'Clear', onPressed: _clear, icon: const Icon(Icons.delete_sweep_outlined))],
      ),
      body: FutureBuilder<List<Transfer>>(
        future: _list,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          final list = [
            for (final t in all)
              if (_filter == 0 || (_filter == 1) == t.incoming) t,
          ];
          final rows = <Widget>[];
          DateTime? day;
          for (final (i, t) in list.indexed) {
            final d = DateTime(t.at.year, t.at.month, t.at.day);
            if (d != day) {
              day = d;
              rows.add(Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(formatSectionDay(d), style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ));
            }
            rows.add(Dismissible(
              key: ValueKey(t.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Icon(Icons.delete_outline_rounded),
              ),
              onDismissed: (_) => db.deleteTransfer(t.id!),
              child: ListTile(
                onTap: () => _open(t),
                leading: Stack(clipBehavior: Clip.none, children: [
                  FileBadge(mime: t.mime, name: t.fileName),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: t.incoming ? Colors.green : Theme.of(context).colorScheme.primary,
                      child: Icon(t.incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ]),
                title: Text(t.isText ? t.text! : t.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${t.incoming ? 'From' : 'To'} ${t.peer} · ${formatTime(t.at)}${t.isText ? '' : ' · ${formatBytes(t.size)}'}'),
              ),
            ).animate().fadeIn(delay: (20 * i.clamp(0, 15)).ms));
          }
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('All')),
                  ButtonSegment(value: 1, label: Text('Received')),
                  ButtonSegment(value: 2, label: Text('Sent')),
                ],
                selected: {_filter},
                onSelectionChanged: (v) => setState(() => _filter = v.first),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text('Nothing here yet.', style: text.bodyLarge))
                  : ListView(padding: const EdgeInsets.only(bottom: 24), children: rows),
            ),
          ]);
        },
      ),
    );
  }
}
