import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../share/protocol.dart';
import '../share/send_center.dart';
import 'island.dart';
import 'motion.dart';

/// A device you can send to: found on Wi-Fi (LocalSend), remembered from
/// before, or found over Nearby (no network).
class Target {
  Target.lan(LsDevice this.device, {this.saved})
      : nearbyName = null,
        online = true;
  Target.saved(SavedDevice this.saved, LsDevice this.device, {required this.online}) : nearbyName = null;
  Target.nearby(String this.nearbyName)
      : device = null,
        saved = null,
        online = true;

  final LsDevice? device;
  final SavedDevice? saved;
  final String? nearbyName;
  final bool online;

  String get name => nearbyName ?? device!.alias;
  bool get favourite => saved?.favorite ?? false;
  String get key => nearbyName != null ? 'nearby:$nearbyName' : device!.fingerprint;

  IconData get icon {
    if (nearbyName != null) return Icons.bluetooth_connected_rounded;
    final type = device?.info.deviceType.name ?? saved?.type;
    return switch (type) {
      'desktop' => Icons.computer_rounded,
      'web' => Icons.public_rounded,
      'server' || 'headless' => Icons.dns_rounded,
      _ => Icons.smartphone_rounded,
    };
  }

  String get subtitle {
    if (nearbyName != null) return 'Nearby · no network needed';
    final model = device?.info.deviceModel ?? saved?.model;
    return [
      ?model,
      if (!online) 'not seen now' else device!.ip,
    ].join(' · ');
  }
}

/// A stand-in for a remembered device that isn't announcing right now; a
/// send to it waits until it shows up.
LsDevice deviceFor(SendCenter s, SavedDevice d) =>
    s.discovery.byFingerprint(d.fingerprint) ??
    LsDevice(
      info: LsInfo(
        alias: d.alias,
        fingerprint: d.fingerprint,
        deviceModel: d.model,
        port: d.port ?? lsPort,
        protocol: d.protocol ?? 'https',
      ),
      ip: d.ip ?? '',
      lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
    );

/// The nearby-devices panel, LocalSend style: a radar while looking,
/// favourites first, then everything on the network and over Nearby.
/// Long-press a device to make it a favourite.
class DevicePicker extends StatefulWidget {
  const DevicePicker({super.key, required this.sharing, required this.onPick, this.enabled = true});

  final SendCenter sharing;
  final ValueChanged<Target> onPick;
  final bool enabled;

  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  SendCenter get s => widget.sharing;
  List<SavedDevice> _saved = const [];

  @override
  void initState() {
    super.initState();
    s.open();
    _load();
  }

  @override
  void dispose() {
    s.close();
    if (!s.jobs.any((j) => j.nearby && !j.finished)) s.nearby.stopDiscovery();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await s.db.savedDevices();
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _toggleFavourite(Target t) async {
    final d = t.device;
    if (d == null) return;
    Haptics.lift();
    if (t.saved == null) {
      await s.db.saveDevice(
        fingerprint: d.fingerprint,
        alias: d.alias,
        model: d.info.deviceModel,
        type: d.info.deviceType.name,
        ip: d.ip,
        port: d.info.port,
        protocol: d.info.protocol,
      );
    }
    await s.db.setFavoriteDevice(d.fingerprint, !t.favourite);
    await _load();
    if (!mounted) return;
    Island.toast(t.favourite ? 'Unfavourited' : '${t.name} ♥',
        icon: t.favourite ? Icons.favorite_border_rounded : Icons.favorite_rounded);
  }

  Future<void> _enterAddress() async {
    final text = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect by address'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('The other device shows its address on its Receive screen (LocalSend: Settings › Network).'),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Nothing answered at $ip. Is LocalSend or ShareBro open there?')));
    }
  }

  List<Target> _targets() {
    final out = <Target>[];
    final seen = <String>{};
    final savedBy = {for (final d in _saved) d.fingerprint: d};
    // Favourites first (even when they're not around right now).
    for (final d in _saved.where((d) => d.favorite)) {
      final live = s.discovery.byFingerprint(d.fingerprint);
      out.add(Target.saved(d, live ?? deviceFor(s, d), online: live != null));
      seen.add(d.fingerprint);
    }
    for (final d in s.discovery.devices) {
      if (seen.add(d.fingerprint)) out.add(Target.lan(d, saved: savedBy[d.fingerprint]));
    }
    for (final name in s.nearby.endpoints.values.toSet()) {
      out.add(Target.nearby(name));
    }
    // Then recent devices that aren't here now.
    for (final d in _saved.take(6)) {
      if (seen.add(d.fingerprint)) out.add(Target.saved(d, deviceFor(s, d), online: false));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([s.discovery, s.nearby]),
      builder: (context, _) {
        final targets = _targets();
        final anyOnline = targets.any((t) => t.online);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Nearby devices', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              tooltip: 'Scan the network',
              onPressed: s.discovery.scanning ? null : s.discovery.scanSubnet,
              icon: s.discovery.scanning
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              tooltip: s.nearby.discovering ? 'Stop Nearby' : 'Find phones without Wi-Fi (Nearby)',
              onPressed: () => s.nearby.discovering ? s.nearby.stopDiscovery() : s.nearby.startDiscovery(),
              icon: Icon(s.nearby.discovering ? Icons.bluetooth_searching_rounded : Icons.bluetooth_rounded,
                  color: s.nearby.discovering ? scheme.primary : null),
            ),
            IconButton(tooltip: 'Connect by address', onPressed: _enterAddress, icon: const Icon(Icons.dialpad_rounded)),
          ]),
          if (!anyOnline)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                const SizedBox(height: 150, child: Radar()),
                Text(
                  'Looking for devices… They need LocalSend or ShareBro open on the same Wi-Fi or hotspot. '
                  'Tap the Bluetooth icon to find ShareBro phones without Wi-Fi.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall,
                ),
              ]),
            ),
          for (final (i, t) in targets.indexed)
            DeviceCard(
              key: ValueKey(t.key),
              target: t,
              onTap: widget.enabled ? () => widget.onPick(t) : null,
              onLongPress: t.device == null ? null : () => _toggleFavourite(t),
            ).animate().fadeIn(delay: (40 * i.clamp(0, 10)).ms, duration: 260.ms).moveY(begin: 10, curve: Curves.easeOutCubic),
        ]);
      },
    );
  }
}

/// A paper plane takes off from [from] (global position) and flies up and
/// away, as a "sent!" flourish.
void flyPaperPlane(BuildContext context, Offset from) {
  if (MediaQuery.disableAnimationsOf(context)) return;
  final overlay = Overlay.of(context);
  final color = Theme.of(context).colorScheme.primary;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 650),
        onEnd: entry.remove,
        builder: (context, t, _) {
          // A gentle arc up and to the right, growing then fading out.
          final e = Curves.easeInCubic.transform(t);
          final pos = from + Offset(220 * e, -60 * t - 380 * e * e);
          return Stack(children: [
            Positioned(
              left: pos.dx - 16,
              top: pos.dy - 16,
              child: Opacity(
                opacity: (1 - t * t).clamp(0, 1),
                child: Transform.rotate(
                  angle: -0.5 - 0.4 * e,
                  child: Transform.scale(
                    scale: 1 + 0.8 * math.sin(t * math.pi),
                    child: Icon(Icons.send_rounded, size: 32, color: color),
                  ),
                ),
              ),
            ),
          ]);
        },
      ),
    ),
  );
  overlay.insert(entry);
}

/// One device, with an "online" dot and a heart for favourites.
class DeviceCard extends StatefulWidget {
  const DeviceCard({super.key, required this.target, this.onTap, this.onLongPress});

  final Target target;
  final VoidCallback? onTap, onLongPress;

  @override
  State<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<DeviceCard> {
  final _sendIcon = GlobalKey();
  bool _launching = false;

  Future<void> _tap() async {
    final onTap = widget.onTap;
    if (onTap == null || _launching) return;
    final box = _sendIcon.currentContext?.findRenderObject() as RenderBox?;
    if (box != null) {
      setState(() => _launching = true);
      flyPaperPlane(context, box.localToGlobal(box.size.center(Offset.zero)));
      // Let the plane get going before the next screen slides in.
      await Future<void>.delayed(const Duration(milliseconds: 420));
      if (mounted) setState(() => _launching = false);
    }
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.target;
    final onTap = widget.onTap;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Pressable(
        onTap: onTap == null ? null : _tap,
        child: GestureDetector(
          onLongPress: widget.onLongPress,
          child: Card(
            margin: EdgeInsets.zero,
            color: t.favourite ? scheme.primaryContainer.withValues(alpha: 0.7) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: t.online
                            ? [scheme.primary, scheme.tertiary]
                            : [scheme.surfaceContainerHighest, scheme.surfaceContainerHigh],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Icon(t.icon, color: t.online ? scheme.onPrimary : scheme.outline),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: t.online ? Colors.green : scheme.outline,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                      ),
                      if (t.favourite) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.favorite_rounded, size: 15, color: Color(0xFFE8457A)),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(t.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                AnimatedOpacity(
                  key: _sendIcon,
                  opacity: _launching ? 0 : 1,
                  duration: 120.ms,
                  child: Icon(Icons.send_rounded, color: onTap == null ? scheme.outline : scheme.primary),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sweeping radar rings, shown while looking for devices.
class Radar extends StatefulWidget {
  const Radar({super.key, this.icon = Icons.wifi_tethering_rounded});

  final IconData icon;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: Stack(alignment: Alignment.center, children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _RadarPainter(still ? const AlwaysStoppedAnimation(0.35) : _c, scheme.primary),
          ),
        ),
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [scheme.primary, scheme.tertiary]),
            boxShadow: [BoxShadow(color: scheme.primary.withValues(alpha: 0.4), blurRadius: 18)],
          ),
          child: Icon(widget.icon, color: scheme.onPrimary),
        ),
      ]),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.anim, this.color) : super(repaint: anim);

  final Animation<double> anim;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = math.min(size.width, size.height) / 2;
    // Three rings ripple outwards, fading as they grow.
    for (var k = 0; k < 3; k++) {
      final t = (anim.value + k / 3) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - t) * 0.5);
      canvas.drawCircle(c, 28 + t * (maxR - 28), paint);
    }
    // A soft sweeping beam.
    final sweep = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2,
        colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.22)],
        transform: GradientRotation(anim.value * 2 * math.pi),
      ).createShader(Rect.fromCircle(center: c, radius: maxR));
    canvas.drawCircle(c, maxR, sweep);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.color != color;
}
