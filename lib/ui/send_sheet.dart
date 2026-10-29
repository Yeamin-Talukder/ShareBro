import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import '../share/protocol.dart';
import '../share/send_center.dart';
import 'motion.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';

/// "Send N photos to Rahim": nearby phones (LocalSend), a QR code for any
/// browser, or Android's share sheet (Quick Share, WhatsApp, Bluetooth…).
Future<void> showSendSheet(
  BuildContext context, {
  required ScanController controller,
  required int personId,
  required String personName,
  required List<String> assetIds,
  required Future<void> Function(List<String> ids) shareWithApps,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _SendSheet(
      controller: controller,
      personId: personId,
      personName: personName,
      assetIds: assetIds,
      shareWithApps: shareWithApps,
    ),
  );
}

class _SendSheet extends StatefulWidget {
  const _SendSheet({
    required this.controller,
    required this.personId,
    required this.personName,
    required this.assetIds,
    required this.shareWithApps,
  });

  final ScanController controller;
  final int personId;
  final String personName;
  final List<String> assetIds;
  final Future<void> Function(List<String> ids) shareWithApps;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  SendCenter get s => widget.controller.sharing;
  late SendQuality _quality = s.defaultQuality;
  Set<String> _sent = const {};
  bool _onlyNew = true;
  List<SavedDevice> _paired = const [];

  @override
  void initState() {
    super.initState();
    s.open();
    _load();
  }

  @override
  void dispose() {
    s.close();
    // Queued Nearby sends restart discovery themselves when they run.
    if (!s.jobs.any((j) => j.nearby && !j.finished)) s.nearby.stopDiscovery();
    super.dispose();
  }

  Future<void> _sendNearby(String name) async {
    final ids = _ids;
    if (ids.isEmpty) return;
    Haptics.success();
    final job = await s.enqueueNearby(
      personId: widget.personId,
      personName: widget.personName,
      assetIds: ids,
      name: name,
      quality: _quality,
    );
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => TransferScreen(controller: widget.controller, job: job)));
  }

  Future<void> _load() async {
    final sent = await s.db.sentTo(widget.personId);
    final paired = await s.db.savedDevices(personId: widget.personId);
    if (mounted) {
      setState(() {
        _sent = sent;
        _paired = paired;
      });
    }
  }

  List<String> get _ids => _onlyNew
      ? [for (final id in widget.assetIds) if (!_sent.contains(id)) id]
      : widget.assetIds;

  Future<void> _sendTo(LsDevice device) async {
    final ids = _ids;
    if (ids.isEmpty) return;
    Haptics.success();
    final job = await s.enqueue(
      personId: widget.personId,
      personName: widget.personName,
      assetIds: ids,
      device: device,
      quality: _quality,
    );
    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => TransferScreen(controller: widget.controller, job: job)));
  }

  /// A paired phone that isn't announcing right now still gets queued; it
  /// starts as soon as the phone shows up.
  LsDevice _deviceFor(SavedDevice d) =>
      s.discovery.byFingerprint(d.fingerprint) ??
      LsDevice(
        info: LsInfo(
          alias: d.alias,
          fingerprint: d.fingerprint,
          port: d.port ?? lsPort,
          protocol: d.protocol ?? 'https',
        ),
        ip: d.ip ?? '',
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
      );

  Future<void> _enterAddress() async {
    final text = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect by address'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('In LocalSend on the other phone, the address is under Settings › Network (or tap the device name on its Receive screen).'),
          const SizedBox(height: 12),
          TextField(
            controller: text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(hintText: '192.168.1.23'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: const Text('Connect')),
        ],
      ),
    );
    if (ip == null || ip.isEmpty) return;
    final parts = ip.split(':');
    final found = await s.discovery.probe(parts.first, port: int.tryParse(parts.length > 1 ? parts[1] : '') ?? lsPort);
    if (!mounted) return;
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nothing answered at $ip. Is LocalSend open on that phone?')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final already = widget.assetIds.where(_sent.contains).length;
    final count = _ids.length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: Listenable.merge([s.discovery, s.nearby]),
        builder: (context, _) {
          final pairedFps = {for (final d in _paired) d.fingerprint};
          final nearby = [for (final d in s.discovery.devices) if (!pairedFps.contains(d.fingerprint)) d];
          return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
            Text('Send $count photos to ${widget.personName}',
                style: text.headlineSmall),
            if (already > 0)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only photos not sent yet'),
                subtitle: Text('$already of ${widget.assetIds.length} were already sent to ${widget.personName}'),
                value: _onlyNew,
                onChanged: (v) => setState(() => _onlyNew = v),
              ),
            const SizedBox(height: 8),
            SegmentedButton<SendQuality>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: SendQuality.original, label: Text('Original')),
                ButtonSegment(value: SendQuality.noLocation, label: Text('No location')),
                ButtonSegment(value: SendQuality.smaller, label: Text('Smaller')),
              ],
              selected: {_quality},
              onSelectionChanged: (v) => setState(() => _quality = v.first),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(switch (_quality) {
                SendQuality.original => 'Full quality, exactly as taken.',
                SendQuality.noLocation => 'Full quality, without GPS location and camera details.',
                SendQuality.smaller => 'Up to 2048 px, no location — much quicker to send.',
              }, style: text.bodySmall),
            ),
            _Section('Nearby phones', Icons.wifi_tethering, trailing: [
              IconButton(
                tooltip: 'Scan the network',
                onPressed: s.discovery.scanning ? null : s.discovery.scanSubnet,
                icon: s.discovery.scanning
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar),
              ),
              IconButton(
                tooltip: 'Connect by address',
                onPressed: _enterAddress,
                icon: const Icon(Icons.dialpad),
              ),
            ]),
            for (final d in _paired)
              _DeviceTile(
                title: d.alias,
                subtitle: s.discovery.byFingerprint(d.fingerprint) != null
                    ? '${widget.personName}\'s phone · nearby'
                    : '${widget.personName}\'s phone · sends when it\'s nearby',
                icon: Icons.phone_android,
                highlight: true,
                online: s.discovery.byFingerprint(d.fingerprint) != null,
                onTap: count == 0 ? null : () => _sendTo(_deviceFor(d)),
              ),
            for (final (i, d) in nearby.indexed)
              _DeviceTile(
                title: d.alias,
                subtitle: [
                  if (d.info.deviceModel != null) d.info.deviceModel!,
                  d.ip,
                ].join(' · '),
                icon: switch (d.info.deviceType) {
                  LsDeviceType.desktop => Icons.computer,
                  LsDeviceType.web => Icons.public,
                  _ => Icons.phone_android,
                },
                online: true,
                onTap: count == 0 ? null : () => _sendTo(d),
              ).animate().fadeIn(delay: (40 * i).ms).moveX(begin: 12),
            if (_paired.isEmpty && nearby.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Looking for phones… Ask ${widget.personName} to open LocalSend '
                      '(free on Play Store and App Store) on the same Wi-Fi or your hotspot.',
                      style: text.bodyMedium,
                    ),
                  ),
                ]),
              ),
            _Section('Phones with this app — no Wi-Fi needed', Icons.bluetooth_searching),
            if (!s.nearby.discovering)
              _OptionTile(
                icon: Icons.bluetooth_searching,
                title: 'Find phones nearby',
                subtitle: 'Uses Bluetooth and Wi-Fi Direct. ${widget.personName} opens Receive in this app.',
                color: scheme.primaryContainer,
                onTap: () => s.nearby.startDiscovery(),
              )
            else if (s.nearby.endpoints.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text('Looking… ${widget.personName} needs this app open with Receive turned on.',
                        style: text.bodyMedium),
                  ),
                ]),
              )
            else
              for (final name in s.nearby.endpoints.values.toSet())
                _DeviceTile(
                  title: name,
                  subtitle: 'Nearby · no network needed',
                  icon: Icons.bluetooth_connected,
                  online: true,
                  onTap: count == 0 ? null : () => _sendNearby(name),
                ),
            _Section('Anyone with a browser', Icons.qr_code_2),
            _OptionTile(
              icon: Icons.qr_code_2,
              title: 'Show a QR code',
              subtitle: 'They scan it and download in their browser — nothing to install, works on iPhone too.',
              color: scheme.tertiaryContainer,
              onTap: count == 0
                  ? null
                  : () {
                      final nav = Navigator.of(context);
                      nav.pop();
                      nav.push(MaterialPageRoute(
                        builder: (_) => WebShareScreen(
                          controller: widget.controller,
                          title: '${widget.personName}\'s photos',
                          assetIds: _ids,
                          quality: _quality,
                        ),
                      ));
                    },
            ),
            _Section('Other apps', Icons.ios_share),
            _OptionTile(
              icon: Icons.share,
              title: 'Quick Share, WhatsApp, Bluetooth…',
              subtitle: 'Android\'s share sheet (originals, up to 100 per batch).',
              color: scheme.secondaryContainer,
              onTap: count == 0
                  ? null
                  : () async {
                      final ids = _ids;
                      Navigator.pop(context);
                      await widget.shareWithApps(ids);
                    },
            ),
          ]);
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.icon, {this.trailing = const []});

  final String title;
  final IconData icon;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        ...trailing,
      ]),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.online,
    required this.onTap,
    this.highlight = false,
  });

  final String title, subtitle;
  final IconData icon;
  final bool online, highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: onTap,
        child: Card(
          color: highlight ? scheme.primaryContainer : null,
          child: ListTile(
            leading: Stack(clipBehavior: Clip.none, children: [
              CircleAvatar(child: Icon(icon)),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: online ? Colors.green : scheme.outline,
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 2),
                  ),
                ),
              ),
            ]),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.send_rounded),
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title, subtitle;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Card(
        child: ListTile(
          leading: CircleAvatar(backgroundColor: color, child: Icon(icon)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}
