import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anim.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/device.dart';
import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import '../share/native_files.dart';
import '../share/server.dart';
import 'aurora.dart';
import 'desktop_layout.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';
import 'theme.dart';

/// A personal web gallery behind a QR code. Friends on the same Wi-Fi or
/// your hotspot scan it and download in their browser — no app needed.
/// The link stays open (also in the background) until "Stop sharing".
class WebShareScreen extends StatefulWidget {
  const WebShareScreen({
    super.key,
    required this.controller,
    required this.title,
    this.assetIds = const [],
    this.items = const [],
    this.quality = SendQuality.original,
    this.existing,
  });

  final ScanController controller;
  final String title;
  final List<String> assetIds;

  /// Files and messages to offer besides [assetIds].
  final List<SendItem> items;
  final SendQuality quality;

  /// Reopens a link that's already shared, instead of making a new one.
  final WebShare? existing;

  @override
  State<WebShareScreen> createState() => _WebShareScreenState();
}

class _WebShareScreenState extends State<WebShareScreen> {
  WebShare? _share;
  String? _link;
  int _prepared = 0;
  String? _error;

  /// Desktop: "Copied" shows on the button for a moment.
  bool _copied = false;
  Timer? _copiedTimer;

  /// Stop sharing was pressed (so leaving needs no reminder).
  bool _stopped = false;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    // Leaving while the link is still open: say so, and where to stop it.
    final share = _share;
    if (!_stopped && share != null && widget.controller.sharing.server.shares.containsKey(share.id)) {
      final title = share.title;
      // After this frame: the tree is locked while pages are disposed.
      Future.microtask(() => Island.toast(
        Device.desktop
            ? 'Still sharing "$title" · stop it under Sharing now in the sidebar'
            : 'Still sharing "$title" · stop it under Sending',
        icon: Icons.qr_code_2_rounded,
      ));
    }
    super.dispose();
  }

  void _copy() {
    final link = _link;
    if (link == null) return;
    Clipboard.setData(ClipboardData(text: link));
    Haptics.tick();
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _retry() {
    setState(() {
      _error = null;
      _prepared = 0;
    });
    _start();
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final s = widget.controller.sharing;
    final existing = widget.existing;
    if (existing != null) {
      final link = await s.server.linkFor(existing);
      if (mounted) {
        setState(() {
          _share = existing;
          _link = link;
          if (link == null) _error = 'Connect to Wi-Fi or turn on your hotspot.';
        });
      }
      return;
    }
    try {
      final share = await s.openWebShare(widget.title, widget.assetIds,
          items: widget.items, quality: widget.quality,
          onProgress: (done, _) {
        if (mounted && done % 5 == 0) setState(() => _prepared = done);
      });
      final link = await s.server.linkFor(share);
      if (!mounted) {
        await s.server.closeShare(share.id);
        return;
      }
      setState(() {
        _share = share;
        _link = link;
        if (link == null) _error = 'Connect to Wi-Fi or turn on your hotspot, then try again.';
      });
      Haptics.success();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _stop() async {
    _stopped = true;
    final share = _share;
    if (share != null) await widget.controller.sharing.server.closeShare(share.id);
    if (mounted) Navigator.pop(context);
  }

  void _togglePin() {
    final share = _share;
    if (share == null) return;
    setState(() {
      share.pin = share.pin == null
          ? (1000 + math.Random.secure().nextInt(9000)).toString()
          : null;
    });
    Haptics.tick();
  }

  /// Desktop: the QR code on the left; on the right the link to copy or
  /// open, who opened it, the PIN and what's shared. Stop sharing sits in
  /// the header.
  Widget _desktop(BuildContext context) {
    final share = _share, link = _link;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ready = share != null && link != null;
    final total = widget.assetIds.length + widget.items.length;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 24, 8),
      child: Row(children: [
        GlassIconButton(
          tooltip: 'Back (Esc)',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.maybePop(context),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.headlineSmall),
            Row(children: [
              if (ready) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: Mac.green, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                ready ? 'Live · shared as a link on this network' : 'Getting the link ready',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ]),
          ]),
        ),
        if (ready)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            onPressed: _stop,
            icon: const Icon(Icons.stop_circle_outlined, size: 17),
            label: const Text('Stop sharing'),
          ),
      ]),
    );

    Widget body;
    if (!ready) {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_error == null) ...[
              Text('Getting $_prepared of $total ready…', style: text.titleSmall),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: total == 0 ? null : (_prepared / total).clamp(0.0, 1.0),
                  minHeight: 6,
                ),
              ),
            ] else ...[
              Icon(Icons.wifi_off_rounded, size: 44, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: text.bodyLarge),
              const SizedBox(height: 16),
              FilledButton(onPressed: _retry, child: const Text('Try again')),
            ],
          ]),
        ),
      );
    } else {
      final qr = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Mac.hairline(context), width: 0.5),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 10, offset: Offset(0, 3))],
        ),
        child: QrImageView(
          data: link,
          size: 248,
          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF1A1820)),
          dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF1A1820)),
        ),
      ).animate().fadeIn(duration: 250.ms).scaleXY(begin: 0.94, curve: Curves.easeOutCubic);

      final linkBox = Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(Mac.controlRadius),
          border: Border.all(color: Mac.hairline(context), width: 0.5),
        ),
        child: Row(children: [
          Icon(Icons.link_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(link, maxLines: 1, style: const TextStyle(fontSize: TextSize.caption)),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 12)),
            onPressed: _copy,
            icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 16),
            label: Text(_copied ? 'Copied' : 'Copy'),
          ),
        ]),
      );

      Widget stat(String number, String label, IconData icon) => Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: Mac.card(context),
                borderRadius: BorderRadius.circular(Mac.cardRadius),
                border: Border.all(color: Mac.hairline(context), width: 0.5),
              ),
              child: Row(children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(number, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ]),
            ),
          );

      final pin = share.pin;
      final details = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Or open this link', style: text.titleSmall),
        const SizedBox(height: 8),
        linkBox,
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
            onPressed: () => NativeFiles.open(link),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Open in browser'),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          stat('${share.visitors.length}', share.visitors.length == 1 ? 'device opened it' : 'devices opened it',
              Icons.devices_rounded),
          const SizedBox(width: 10),
          stat('${share.downloads}', share.downloads == 1 ? 'download' : 'downloads', Icons.download_rounded),
        ]),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: Mac.card(context),
            borderRadius: BorderRadius.circular(Mac.cardRadius),
            border: Border.all(color: Mac.hairline(context), width: 0.5),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InkWell(
              mouseCursor: SystemMouseCursors.click,
              onTap: _togglePin,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(children: [
                  Icon(Icons.pin_outlined, size: 20, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Protect with a PIN', style: TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w500)),
                      Text(
                        pin == null
                            ? 'Anyone on this network with the link can open it'
                            : 'They type this code before they see anything',
                        style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant),
                      ),
                    ]),
                  ),
                  Switch(value: pin != null, onChanged: (_) => _togglePin()),
                ]),
              ),
            ),
            AnimatedSize(
              duration: 200.ms,
              alignment: Alignment.topCenter,
              child: pin == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(46, 0, 14, 14),
                      child: Row(children: [
                        for (final d in pin.split('')) ...[
                          Container(
                            width: 40,
                            height: 48,
                            margin: const EdgeInsets.only(right: 8),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(Mac.controlRadius),
                            ),
                            child: Text(d,
                                style: TextStyle(
                                    fontSize: TextSize.title2, fontWeight: FontWeight.w700, color: scheme.primary)),
                          ),
                        ],
                      ]),
                    ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Icon(Icons.photo_library_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${share.files.length} ${share.files.length == 1 ? 'file' : 'files'} · '
              '${share.parts.length > 1 ? 'Download all comes as ${share.parts.length} ZIP parts' : 'download all as one ZIP, or one by one'}',
              style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
            ),
          ),
        ]),
      ]);

      body = ListView(padding: const EdgeInsets.fromLTRB(24, 16, 24, 32), children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Mac.card(context),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Mac.hairline(context), width: 0.5),
              ),
              child: LayoutBuilder(builder: (context, box) {
                final side = box.maxWidth >= 640;
                final left = Column(mainAxisSize: MainAxisSize.min, children: [
                  qr,
                  const SizedBox(height: 12),
                  Text('Scan with a phone camera', style: text.titleSmall),
                  Text('No app needed', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]);
                return side
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        left,
                        const SizedBox(width: 28),
                        Expanded(child: details),
                      ])
                    : Column(children: [left, const SizedBox(height: 24), details]);
              }),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Text(
              'Works for anyone on the same Wi‑Fi as this computer. You can leave this page; '
              'the link keeps working while ShareBro is open. Find it again under Sending.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ]);
    }

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        Expanded(
          child: ready
              ? ListenableBuilder(listenable: widget.controller.sharing.server, builder: (context, _) => body)
              : body,
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopLayout.on) return _desktop(context);
    final share = _share;
    final text = Theme.of(context).textTheme;
    return Aurora(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(widget.title)),
        body: share == null || _link == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_error == null) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('Getting $_prepared of ${widget.assetIds.length + widget.items.length} ready…'),
                    ] else ...[
                      const Icon(Icons.wifi_off_rounded, size: 48),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center),
                    ],
                  ]),
                ),
              )
            : ListenableBuilder(
                listenable: widget.controller.sharing.server,
                builder: (context, _) => ListView(padding: DesktopLayout.pad(context, const EdgeInsets.all(20)), children: [
                  Center(
                    child: Glass(
                      radius: 32,
                      padding: const EdgeInsets.all(20),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: QrImageView(
                            data: _link!,
                            size: 220,
                            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF1A1820)),
                            dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF1A1820)),
                          ),
                        ).animate().scaleXY(begin: 0.6, duration: 600.ms, curve: Curves.elasticOut),
                        const SizedBox(height: 14),
                        Text('Scan with the phone camera', style: text.titleMedium),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: _link!));
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(content: Text('Link copied')));
                          },
                          child: Text(_link!, style: text.bodySmall),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: Column(children: [
                      ListTile(
                        leading: const Icon(Icons.photo_library_outlined),
                        title: Text('${share.files.length} photos'),
                        subtitle: Text(share.parts.length > 1
                            ? 'Download all comes as ${share.parts.length} ZIP parts'
                            : 'Download all as one ZIP, or tap photos one by one'),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.pin_outlined),
                        title: Text(share.pin == null ? 'Protect with a PIN' : 'PIN: ${share.pin}'),
                        subtitle: Text(share.pin == null
                            ? 'Anyone on this network with the QR code can open it'
                            : 'Tell ${widget.title.split('\'').first} this code'),
                        value: share.pin != null,
                        onChanged: (_) => _togglePin(),
                      ),
                      ListTile(
                        leading: const Icon(Icons.visibility_outlined),
                        title: Text(share.visitors.isEmpty
                            ? 'Nobody has opened it yet'
                            : '${share.visitors.length} ${share.visitors.length == 1 ? 'device' : 'devices'} opened it'),
                        subtitle: Text('${share.downloads} downloads so far'),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    Device.desktop
                        ? 'They need to be on the same Wi-Fi as this computer. '
                            'You can leave this screen; the link keeps working while ShareBro is open. '
                            'Find it again under Sending.'
                        : 'They need to be on the same Wi-Fi as you, or connected to your phone\'s hotspot. '
                            'You can leave this screen or lock your phone — the link keeps working until you stop it. '
                            'Find it again under Sending.',
                    style: text.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _stop,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop sharing'),
                  ),
                ]),
              ),
      ),
    );
  }
}
