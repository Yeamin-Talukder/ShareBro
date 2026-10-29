import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../scan/scan_controller.dart';
import '../share/net.dart';
import '../share/receive.dart';
import 'aurora.dart';
import 'glass.dart';
import 'island.dart';
import 'motion.dart';

/// Receive mode: friends send you their photos from LocalSend (same Wi-Fi
/// or hotspot) or from this app over Nearby (no network). They're saved to
/// the "ShareBro" album and scanned for faces.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  String? _ip;

  @override
  void initState() {
    super.initState();
    localIp().then((ip) {
      if (mounted) setState(() => _ip = ip);
    });
  }

  Future<void> _toggle(bool on) async {
    Haptics.tick();
    await widget.controller.sharing.setReceiving(on);
  }

  Future<void> _setPin(Receiver r) async {
    if (r.pin != null) {
      await r.setPin(null);
      return;
    }
    await r.setPin((1000 + math.Random.secure().nextInt(9000)).toString());
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.controller.sharing;
    final r = s.receiver;
    final text = Theme.of(context).textTheme;
    return Aurora(
      intensity: 0.8,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Receive')),
        body: ListenableBuilder(
          listenable: Listenable.merge([s, r]),
          builder: (context, _) {
            final session = r.session;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Center(
                child: Glass(
                  radius: 32,
                  padding: const EdgeInsets.all(22),
                  child: Column(children: [
                    AnimatedContainer(
                      duration: 300.ms,
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: r.enabled
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                      child: Icon(Icons.download_rounded,
                          size: 46,
                          color: r.enabled
                              ? Theme.of(context).colorScheme.onPrimary
                              : Theme.of(context).colorScheme.outline),
                    )
                        .animate(target: r.enabled ? 1 : 0, onPlay: (c) => r.enabled ? c.repeat(reverse: true) : null)
                        .scaleXY(end: 1.06, duration: 1100.ms, curve: Curves.easeInOut),
                    const SizedBox(height: 14),
                    Text(r.enabled ? 'Ready to receive' : 'Receiving is off', style: text.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      r.enabled
                          ? 'Friends see you as "${s.identity.alias}"'
                              '${_ip == null ? '' : ' · $_ip'}'
                          : 'Turn on to let friends send you photos and files',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () => _toggle(!r.enabled),
                      icon: Icon(r.enabled ? Icons.stop_rounded : Icons.play_arrow_rounded),
                      label: Text(r.enabled ? 'Stop receiving' : 'Start receiving'),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              if (session != null) _SessionCard(session: session).animate().fadeIn().moveY(begin: 8),
              Card(
                child: Column(children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.bolt_rounded),
                    title: const Text('Quick save'),
                    subtitle: const Text('Accept everything without asking'),
                    value: r.quickSave,
                    onChanged: r.setQuickSave,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.verified_user_outlined),
                    title: const Text('Accept favourites automatically'),
                    subtitle: const Text('Paired and favourite devices; others ask first'),
                    value: r.autoAcceptPaired,
                    onChanged: r.quickSave ? null : r.setAutoAccept,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.pin_outlined),
                    title: Text(r.pin == null ? 'Require a PIN' : 'PIN: ${r.pin}'),
                    subtitle: Text(r.pin == null
                        ? 'Anyone nearby can ask to send'
                        : 'LocalSend asks the sender for this code'),
                    value: r.pin != null,
                    onChanged: (_) => _setPin(r),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Text(
                'On Wi-Fi or your hotspot, friends use the free LocalSend app and pick "${s.identity.alias}". '
                'Friends with this app can also send with no network at all (Nearby). '
                'Photos go to the "$receivedAlbum" album and are scanned for faces; other files go to '
                'Download/$receivedAlbum. '
                'You can leave the app — it keeps receiving in the background.',
                style: text.bodySmall,
              ),
              if (r.history.where((h) => h.finished).isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Received', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                for (final h in r.history.where((h) => h.finished))
                  ListTile(
                    leading: Icon(h.cancelled ? Icons.cancel_outlined : Icons.check_circle, color: h.cancelled ? null : Colors.green),
                    title: Text('${h.done.length} ${h.savedFiles == 0 ? 'photos' : 'files'} from ${h.from}'),
                    subtitle: Text('${formatTime(h.started)} · ${formatBytes(h.bytes)}'),
                  ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});

  final ReceiveSession session;

  @override
  Widget build(BuildContext context) {
    final total = session.totalBytes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              session.finished
                  ? 'Got ${session.done.length} ${session.savedFiles == 0 ? 'photos' : 'files'} from ${session.from}'
                  : 'Receiving from ${session.from}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: session.finished ? 1 : (total == 0 ? null : session.bytes / total),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 6),
            Text('${session.done.length} of ${session.tokens.length} · ${formatBytes(session.bytes)} of ${formatBytes(total)}',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}

/// Watches for incoming send requests anywhere in the app and asks
/// "Accept 42 photos from Rahim?"; shows messages as they arrive.
class IncomingWatcher extends StatefulWidget {
  const IncomingWatcher({super.key, required this.controller, required this.child});

  final ScanController controller;
  final Widget child;

  @override
  State<IncomingWatcher> createState() => _IncomingWatcherState();
}

class _IncomingWatcherState extends State<IncomingWatcher> {
  IncomingRequest? _shown;

  Receiver get _r => widget.controller.sharing.receiver;

  @override
  void initState() {
    super.initState();
    _r.addListener(_check);
    _r.message.addListener(_showMessage);
  }

  @override
  void dispose() {
    _r.removeListener(_check);
    _r.message.removeListener(_showMessage);
    super.dispose();
  }

  void _showMessage() {
    final m = _r.message.value;
    if (m == null) return;
    _r.message.value = null;
    Haptics.lift();
    showMessageDialog(context, from: m.from, text: m.text);
  }

  /// Requests are answered in the island (see island.dart); this just
  /// gives a nudge when one arrives.
  void _check() {
    final req = _r.pending;
    if (req == null || req == _shown || req.answered) return;
    _shown = req;
    Haptics.lift();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A received text, with Copy.
Future<void> showMessageDialog(BuildContext context, {required String from, required String text}) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.chat_bubble_rounded),
        title: Text('Message from $from'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
              Island.toast('Copied', icon: Icons.copy_rounded);
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
          ),
        ],
      ),
    );

/// "Maya wants to send you 12 photos": who, what, and a ring counting
/// down until the request expires.
