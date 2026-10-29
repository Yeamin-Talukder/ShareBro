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
import '../share/receive.dart';
import 'devices.dart';
import 'file_icons.dart';
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'receive_screen.dart';
import 'send_center_screen.dart';
import 'send_to_sheet.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';

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
      ],
      slivers: [
        SliverPadding(
          // Clear the floating nav bar so the last buttons stay reachable.
          padding: EdgeInsets.fromLTRB(16, 4, 16, MediaQuery.paddingOf(context).bottom + 24),
          sliver: SliverList.list(children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.north_east_rounded), label: Text('Send')),
                ButtonSegment(value: true, icon: Icon(Icons.south_west_rounded), label: Text('Receive')),
              ],
              selected: {_receive},
              onSelectionChanged: (v) {
                Haptics.tick();
                setState(() => _receive = v.first);
              },
            ),
            const SizedBox(height: 16),
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
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(key: const ValueKey('send'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Selection', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Row(children: [
        _PickButton(icon: Icons.photo_library_rounded, label: 'Media', color: const Color(0xFFE8457A), onTap: _pickMedia),
        _PickButton(icon: Icons.insert_drive_file_rounded, label: 'Files', color: const Color(0xFF2B6CD9), onTap: _pickFiles),
        _PickButton(icon: Icons.folder_rounded, label: 'Folder', color: const Color(0xFFB8860B), onTap: _pickFolder),
        _PickButton(icon: Icons.notes_rounded, label: 'Text', color: const Color(0xFF2BB5A6), onTap: _writeText),
        _PickButton(icon: Icons.content_paste_rounded, label: 'Paste', color: const Color(0xFF6E5BFF), onTap: _paste),
      ]),
      AnimatedSize(
        duration: 260.ms,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _items.isEmpty
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text('${describeItems(_items)} selected', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            Haptics.remove();
                            setState(_items.clear);
                          },
                          child: const Text('Clear'),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      ItemStrip(items: List.of(_items), onRemove: (i) => setState(() => _items.remove(i)), height: 76),
                    ]),
                  ),
                ),
              ),
      ),
      const SizedBox(height: 18),
      DevicePicker(
        sharing: c.sharing,
        enabled: _items.isNotEmpty,
        onPick: (t) async {
          final items = List.of(_items);
          setState(_items.clear);
          await sendItemsTo(context, c, t, items);
        },
      ),
      if (_items.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Pick something above, then tap a device to send it.',
              textAlign: TextAlign.center, style: text.bodySmall),
        ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _items.isEmpty
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WebShareScreen(
                          controller: c,
                          title: 'Shared with ShareBro',
                          items: List.of(_items),
                        ),
                      ),
                    ),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: const Text('Link / QR'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _items.isEmpty ? null : () => shareItemsWithApps(List.of(_items)),
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Other apps'),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Text(
        'Works with the free LocalSend app on Android, iPhone, Windows, Mac and Linux on the same Wi-Fi or hotspot, '
        'and with ShareBro phones over Nearby (no Wi-Fi). The link works in any browser.',
        style: text.bodySmall?.copyWith(color: scheme.outline),
      ),
    ]);
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(children: [
            Container(
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Center(child: Icon(icon, color: color, size: 26)),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

/// Being findable: your name and address, on/off, quick save and PIN,
/// and the transfer in progress.
class _ReceivePanel extends StatefulWidget {
  const _ReceivePanel({super.key, required this.controller});

  final ScanController controller;

  @override
  State<_ReceivePanel> createState() => _ReceivePanelState();
}

class _ReceivePanelState extends State<_ReceivePanel> {
  String? _ip;

  @override
  void initState() {
    super.initState();
    localIp().then((ip) {
      if (mounted) setState(() => _ip = ip);
    });
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
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Glass(
            radius: 32,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(children: [
              SizedBox(
                height: 150,
                child: r.enabled
                    ? const Radar(icon: Icons.download_rounded)
                    : Center(
                        child: CircleAvatar(
                          radius: 40,
                          backgroundColor: scheme.surfaceContainerHighest,
                          child: Icon(Icons.download_rounded, size: 38, color: scheme.outline),
                        ),
                      ),
              ),
              const SizedBox(height: 8),
              Text(s.identity.alias, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: 250.ms,
                child: Text(
                  r.enabled ? 'Ready to receive${_ip == null ? '' : ' · $_ip'}' : 'Receiving is off',
                  key: ValueKey(r.enabled),
                  style: text.bodyMedium,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(220, 50)),
                onPressed: () {
                  Haptics.tick();
                  s.setReceiving(!r.enabled);
                },
                icon: Icon(r.enabled ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(r.enabled ? 'Stop receiving' : 'Start receiving'),
              ),
            ]),
          ),
          if (session != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: GestureDetector(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => ReceiveLiveScreen(controller: widget.controller))),
                child: _LiveSession(session: session),
              ),
            ).animate().fadeIn().moveY(begin: 8),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilterChip(
              avatar: const Icon(Icons.bolt_rounded, size: 18),
              label: const Text('Quick save'),
              selected: r.quickSave,
              onSelected: r.setQuickSave,
            ),
            FilterChip(
              avatar: const Icon(Icons.favorite_rounded, size: 18),
              label: const Text('Auto-accept favourites'),
              selected: r.autoAcceptPaired,
              onSelected: r.quickSave ? null : r.setAutoAccept,
            ),
            FilterChip(
              avatar: const Icon(Icons.pin_rounded, size: 18),
              label: Text(r.pin == null ? 'PIN' : 'PIN ${r.pin}'),
              selected: r.pin != null,
              onSelected: (_) => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ReceiveScreen(controller: widget.controller))),
            ),
          ]),
          const SizedBox(height: 10),
          Text(
            r.quickSave
                ? 'Everything is accepted without asking.'
                : 'You\'re asked before anything is saved (favourites and paired phones skip the question).',
            style: text.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Photos and videos go to the "$receivedAlbum" album and are scanned for faces; other files to '
            'Download/$receivedAlbum; messages pop up to copy. Keeps working in the background.',
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
        ]);
      },
    );
  }
}

class _LiveSession extends StatelessWidget {
  const _LiveSession({required this.session});

  final ReceiveSession session;

  @override
  Widget build(BuildContext context) {
    final total = session.totalBytes;
    final card = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(session.finished ? 'Got ${session.done.length} from ${session.from} ✓' : 'Receiving from ${session.from}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: session.finished ? 1 : (total == 0 ? 0 : session.bytes / total)),
              duration: 300.ms,
              builder: (context, v, _) => LinearProgressIndicator(value: v, minHeight: 8),
            ),
          ),
          const SizedBox(height: 6),
          Text('${session.done.length} of ${session.tokens.length} · ${formatBytes(session.bytes)} of ${formatBytes(total)}',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
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
