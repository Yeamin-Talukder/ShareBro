import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:local_auth/local_auth.dart';

import '../scan/scan_controller.dart';
import 'motion.dart';

/// Coming back after this long in the background locks the app again.
const _relockAfter = Duration(seconds: 30);

final _auth = LocalAuthentication();

/// Asks the phone to confirm it's you (fingerprint, face or screen lock).
Future<bool> confirmOwner(String reason) async {
  try {
    if (!await _auth.isDeviceSupported()) return false;
    return await _auth.authenticate(
      localizedReason: reason,
      persistAcrossBackgrounding: true,
    );
  } catch (e) {
    debugPrint('Authentication failed: $e');
    return false;
  }
}

/// Covers the app with a lock screen when app lock is on: at start, and when
/// returning after a while in the background.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final ScanController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late bool _locked = widget.controller.appLock;
  DateTime? _leftAt;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.controller.appLock || _asking) return;
    if (state == AppLifecycleState.paused) {
      _leftAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _leftAt != null) {
      if (DateTime.now().difference(_leftAt!) > _relockAfter) {
        setState(() => _locked = true);
        _unlock();
      }
      _leftAt = null;
    }
  }

  Future<void> _unlock() async {
    if (_asking) return;
    _asking = true;
    final ok = await confirmOwner('Unlock ShareBro');
    _asking = false;
    if (ok && mounted) {
      Haptics.success();
      setState(() => _locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(children: [
      widget.child,
      if (_locked)
        Positioned.fill(
          child: Material(
            color: scheme.surface,
            child: SafeArea(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.lock_rounded, size: 44, color: scheme.onPrimaryContainer),
                )
                    .animate(onPlay: (c) => c.repeat(reverse: true))
                    .scaleXY(end: 1.06, duration: 1200.ms, curve: Curves.easeInOut),
                const SizedBox(height: 24),
                Text('ShareBro is locked',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('Face data stays private on this phone.'),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Unlock'),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}
