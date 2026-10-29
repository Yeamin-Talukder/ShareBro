import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import '../share/server.dart';
import 'aurora.dart';
import 'glass.dart';
import 'motion.dart';

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

  @override
  Widget build(BuildContext context) {
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
                builder: (context, _) => ListView(padding: const EdgeInsets.all(20), children: [
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
                    'They need to be on the same Wi-Fi as you, or connected to your phone\'s hotspot. '
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
