import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../data/gallery.dart';
import '../scan/scan_controller.dart';
import '../share/native_files.dart';
import '../share/net.dart';
import '../share/prepare.dart';
import '../share/protocol.dart';
import '../share/receive.dart';
import 'app_picker.dart';
import 'devices.dart';
import 'file_icons.dart';
import 'find_me_screen.dart';
import 'gallery_view.dart';
import 'group_screen.dart';
import 'glass.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'receive_screen.dart';
import 'send_center_screen.dart';
import 'sections.dart';
import 'send_to_sheet.dart';
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
    if (!await Gallery.requestAccess() || !mounted) return;
    final ids = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('Pick photos & videos')),
          body: GalleryView(
            controller: c,
            source: GallerySource.album(() => Gallery.allPhotos(media: true)),
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
    final s = c.sharing;
    return GlassScrollView(
      title: 'Share',
      actions: [
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
        SliverPadding(
          // Clear the floating nav bar so the last buttons stay reachable.
          padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.paddingOf(context).bottom + 24),
          sliver: SliverList.list(children: [
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

  Widget _sendPanel(BuildContext context) {
    final picked = describeItems(_items);
    return Column(key: const ValueKey('send'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 18),
      SectionCard(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 14),
            child: Row(children: [
              _PickButton(icon: Icons.photo_library_outlined, label: 'Media', onTap: _pickMedia),
              _PickButton(icon: Icons.insert_drive_file_outlined, label: 'Files', onTap: _pickFiles),
              _PickButton(icon: Icons.folder_outlined, label: 'Folder', onTap: _pickFolder),
              _PickButton(icon: Icons.notes_rounded, label: 'Text', onTap: _writeText),
              _PickButton(icon: Icons.content_paste_rounded, label: 'Paste', onTap: _paste),
              _PickButton(icon: Icons.apps_rounded, label: 'Apps', onTap: _pickApps),
            ]),
          ),
          // What's picked appears in the same card, ready to send.
          AnimatedSize(
            duration: 300.ms,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _items.isEmpty
                ? const SizedBox(width: double.infinity)
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Divider(height: 0.5, thickness: 0.5),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 8, 14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text('${picked[0].toUpperCase()}${picked.substring(1)}',
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
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
      ),
      DevicePicker(
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
      ),
      const SizedBox(height: 22),
      SectionCard.rows(rows: [
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
      ]),
      const SectionFooter(
        'Works with the free LocalSend app on Android, iPhone, Windows, Mac and Linux on the same Wi‑Fi or hotspot, '
        'and with ShareBro phones over Nearby, no Wi‑Fi needed. The link works in any browser.',
      ),
    ]);
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
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

/// Being findable: you in the middle of the orbit, on/off, quick save and
/// PIN, the transfer in progress and what arrived lately.
class _ReceivePanel extends StatefulWidget {
  const _ReceivePanel({super.key, required this.controller});

  final ScanController controller;

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
        void toggle() {
          Haptics.tick();
          s.setReceiving(!on);
        }

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 18),
          SectionCard(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(children: [
              Orbit(
                height: 300,
                centreY: 150,
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
                      style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant)),
                ]),
              ),
              const SizedBox(height: 3),
              Text('${_ip ?? 'No network'} · port $lsPort',
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
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
          ),
          if (session != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _LiveSession(session: session, onTap: _openLive),
            ).animate().fadeIn().moveY(begin: 8),
          const SectionHeader(title: 'Options'),
          SectionCard.rows(rows: [
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
              trailing: Text(r.pin ?? 'Off', style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
              chevron: true,
              onTap: () => _editPin(r),
            ),
          ]),
          SectionFooter(r.quickSave
              ? 'Everything is saved without asking.'
              : 'You\'re asked before anything is saved. Favourites and paired phones skip the question.'),
          FutureBuilder<List<Transfer>>(
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
          ),
          SectionFooter(
            'Photos and videos go to the "$receivedAlbum" album and are scanned for faces; other files go to '
            'Download/$receivedAlbum; messages pop up so you can copy them. Receiving keeps working in the background.',
          ),
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
            child: Text(initials, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
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
