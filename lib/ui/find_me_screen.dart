import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../scan/scan_controller.dart';
import '../share/server.dart';
import 'aurora.dart';
import 'glass.dart';
import 'motion.dart';
import 'sections.dart';

/// "Find my photos": one QR code for the whole group. Each friend scans it,
/// takes a selfie in the browser, and gets a gallery of just the photos
/// they're in. Faces are matched on this phone.
class FindMeScreen extends StatefulWidget {
  const FindMeScreen({super.key, required this.controller, this.tripId, this.tripName, this.existing});

  final ScanController controller;

  /// Only this trip's photos, when set.
  final int? tripId;
  final String? tripName;

  /// Reopens a link that's already open.
  final FindLink? existing;

  @override
  State<FindMeScreen> createState() => _FindMeScreenState();
}

class _FindMeScreenState extends State<FindMeScreen> {
  FindLink? _link;
  String? _url;
  String? _error;

  ShareServer get _server => widget.controller.sharing.server;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _server.start();
    final link = widget.existing ?? _server.openFind(widget.tripName ?? 'All photos', tripId: widget.tripId);
    final url = await _server.findLinkFor(link);
    if (!mounted) return;
    setState(() {
      _link = link;
      _url = url;
      if (url == null) _error = 'Connect to Wi-Fi or turn on your hotspot, then try again.';
    });
    if (widget.existing == null && url != null) Haptics.success();
  }

  Future<void> _stop() async {
    final link = _link;
    if (link != null) await _server.closeFind(link.id);
    if (mounted) Navigator.pop(context);
  }

  void _togglePin() {
    final link = _link;
    if (link == null) return;
    setState(() {
      link.pin = link.pin == null ? (1000 + math.Random.secure().nextInt(9000)).toString() : null;
    });
    Haptics.tick();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = _link;
    final url = _url;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassScrollView(
          title: 'Find my photos',
          subtitle: link?.title ?? widget.tripName ?? 'All photos',
          slivers: [
            if (link == null || url == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: _error == null
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.wifi_off_rounded, size: 48, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center),
                          ]),
                        ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
                sliver: ListenableBuilder(
                  listenable: _server,
                  builder: (context, _) => SliverList.list(children: [
                    SectionCard(
                      padding: const EdgeInsets.all(20),
                      child: Column(children: [
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                          child: QrImageView(
                            data: url,
                            size: 210,
                            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF1A1820)),
                            dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF1A1820)),
                          ),
                        ).animate().scaleXY(begin: 0.6, duration: 600.ms, curve: Curves.elasticOut),
                        const SizedBox(height: 14),
                        const Text('Show this to the group',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: url));
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                          },
                          child: Text(url, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                        ),
                      ]),
                    ),
                    const SectionHeader(title: 'How it works'),
                    SectionCard.rows(rows: const [
                      SectionRow(
                        leading: IconTile(icon: Icons.qr_code_scanner_rounded, color: Color(0xFF5E5CE6)),
                        title: 'Friends scan the code',
                        subtitle: 'With the phone camera, no app needed',
                      ),
                      SectionRow(
                        leading: IconTile(icon: Icons.camera_front_rounded, color: Color(0xFFFF9F0A)),
                        title: 'They take a selfie',
                        subtitle: 'This phone works out who they are',
                      ),
                      SectionRow(
                        leading: IconTile(icon: Icons.photo_library_rounded, color: Color(0xFF30D158)),
                        title: 'They get their photos',
                        subtitle: 'Only the ones they\'re in, ready to download',
                      ),
                    ]),
                    const SectionHeader(title: 'This link'),
                    SectionCard.rows(rows: [
                      SectionRow(
                        leading: const IconTile(icon: Icons.pin_rounded, color: Color(0xFFFF453A)),
                        title: link.pin == null ? 'Protect with a PIN' : 'PIN: ${link.pin}',
                        subtitle: link.pin == null
                            ? 'Anyone on this network with the code can use it'
                            : 'Tell the group this code',
                        trailing: Switch(value: link.pin != null, onChanged: (_) => _togglePin()),
                        onTap: _togglePin,
                      ),
                      SectionRow(
                        leading: const IconTile(icon: Icons.face_retouching_natural_rounded, color: Color(0xFF64D2FF)),
                        title: link.found.isEmpty
                            ? 'Nobody found yet'
                            : '${link.found.length} ${link.found.length == 1 ? 'person' : 'people'} found',
                        subtitle: link.found.isEmpty
                            ? (link.tries == 0 ? 'Waiting for the first selfie' : '${link.tries} selfies, no match yet')
                            : link.found.join(', '),
                      ),
                    ]),
                    const SectionFooter(
                      'Everyone needs to be on the same Wi‑Fi as you, or on your hotspot. Selfies are checked on this '
                      'phone and deleted straight away. Someone holding up a photo of a friend could get that friend\'s '
                      'photos, so add a PIN in a crowd. The link keeps working in the background until you stop it.',
                    ),
                    const SizedBox(height: 18),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      onPressed: _stop,
                      icon: const Icon(Icons.stop_circle_rounded),
                      label: const Text('Stop the link'),
                    ),
                  ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
