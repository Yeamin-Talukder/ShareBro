import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/dates.dart';
import '../update/release.dart';
import '../update/updater.dart';
import 'island.dart';
import 'motion.dart';
import 'theme.dart';

/// Opens the update sheet. With [check], asks GitHub first (the "Software
/// update" row in Settings).
Future<void> showUpdateSheet(BuildContext context, {bool check = false}) {
  final u = Updater.instance;
  if (check && !u.busy && !u.hasUpdate) unawaited(u.check(manual: true));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => const _UpdateSheet(),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet();

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> with WidgetsBindingObserver {
  Updater get u => Updater.instance;

  /// Android said no: ShareBro isn't allowed to install apps yet.
  bool _needsPermission = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from "Install unknown apps": carry on if it's now allowed.
    if (state == AppLifecycleState.resumed && _needsPermission) {
      Updater.canInstall().then((ok) {
        if (ok && mounted) {
          setState(() => _needsPermission = false);
          _install();
        }
      });
    }
  }

  Future<void> _update() async {
    Haptics.tick();
    if (await u.shouldAskAboutData()) {
      if (!mounted) return;
      final size = u.apk == null ? 'about 90 MB' : formatBytes(u.apk!.size);
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.signal_cellular_alt_rounded),
          title: const Text('Download on mobile data?'),
          content: Text("You're not on Wi-Fi. This update is $size."),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Wait for Wi-Fi')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Download')),
          ],
        ),
      );
      if (go != true) return;
    }
    unawaited(u.download());
  }

  Future<void> _install() async {
    Haptics.tick();
    final result = await u.install();
    if (!mounted) return;
    switch (result) {
      case InstallResult.started:
        break;
      case InstallResult.needsPermission:
        setState(() => _needsPermission = true);
      case InstallResult.failed:
        Island.toast("Couldn't open the installer", icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: u,
      builder: (context, _) {
        final stage = u.stage;
        final noRelease = u.release == null || u.apk == null;
        final Widget body;
        if (stage == UpdateStage.checking) {
          body = const _Checking(key: ValueKey('checking'));
        } else if (stage == UpdateStage.failed && noRelease) {
          body = _CheckFailed(key: const ValueKey('nocheck'), error: u.error ?? '', onRetry: u.retry);
        } else if (stage == UpdateStage.idle || stage == UpdateStage.upToDate || noRelease) {
          body = _UpToDate(key: const ValueKey('ok'), version: u.currentText);
        } else {
          body = _Flow(
            key: const ValueKey('flow'),
            needsPermission: _needsPermission,
            onUpdate: _update,
            onInstall: _install,
          );
        }
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
            child: AnimatedSize(
              duration: _d(context, 320),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(duration: _d(context, 260), child: body),
            ),
          ),
        );
      },
    );
  }
}

Duration _d(BuildContext context, int ms) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);

// ---- The update itself: what's new → downloading → checking → install ----

class _Flow extends StatelessWidget {
  const _Flow({super.key, required this.needsPermission, required this.onUpdate, required this.onInstall});

  final bool needsPermission;
  final VoidCallback onUpdate, onInstall;

  @override
  Widget build(BuildContext context) {
    final u = Updater.instance;
    final r = u.release!, a = u.apk!;
    final stage = u.stage;
    final title = switch (stage) {
      UpdateStage.downloading => 'Downloading…',
      UpdateStage.verifying => 'Checking the download…',
      UpdateStage.ready => 'Ready to install',
      UpdateStage.failed => u.badFile ? "Download didn't match" : 'Download paused',
      _ => 'Update available',
    };
    final ring = switch (stage) {
      UpdateStage.downloading => _RingMode.progress,
      UpdateStage.verifying => _RingMode.spin,
      UpdateStage.ready => _RingMode.full,
      UpdateStage.failed => u.received > 0 ? _RingMode.progress : _RingMode.none,
      _ => _RingMode.none,
    };
    final meta = [
      formatBytes(a.size),
      shortAbi(a.name),
      if (r.published != null) 'released ${releasedAgo(r.published!, DateTime.now())}',
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Hero(
          title: title,
          ring: ring,
          progress: u.progress,
          done: stage == UpdateStage.ready,
          from: u.currentText,
          to: r.version.toString(),
          meta: meta,
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: _d(context, 260),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a),
              child: child,
            ),
          ),
          child: KeyedSubtree(
            key: ValueKey(stage),
            child: switch (stage) {
              UpdateStage.downloading => _downloading(context, u, a),
              UpdateStage.verifying => const _Shield(
                  text: 'Comparing with the checksum published on GitHub…',
                  busy: true,
                ),
              UpdateStage.ready => _ready(context, u, r),
              UpdateStage.failed => _failed(context, u),
              _ => _available(context, u, r),
            },
          ),
        ),
      ],
    );
  }

  Widget _available(BuildContext context, Updater u, Release r) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (r.notes.isNotEmpty || r.summary.isNotEmpty) _Notes(release: r),
      const SizedBox(height: 16),
      _MainButton(label: 'Update now', icon: Icons.download_rounded, onTap: onUpdate),
      const SizedBox(height: 8),
      _SecondButton(label: 'Later', onTap: () => Navigator.maybePop(context)),
      TextButton(
        onPressed: () {
          Haptics.tick();
          u.skip();
          Navigator.maybePop(context);
        },
        child: const Text('Skip this version'),
      ),
    ]);
  }

  Widget _downloading(BuildContext context, Updater u, ReleaseAsset a) {
    final scheme = Theme.of(context).colorScheme;
    final left = u.remaining;
    final small = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Text('${formatBytes(u.received)} of ${formatBytes(a.size)}', style: small),
        const Spacer(),
        Text(
          [
            if (left != null) _left(left),
            if (u.speed != null) '${formatBytes(u.speed!.round())}/s',
          ].join(' · '),
          style: small,
        ),
      ]),
      const SizedBox(height: 14),
      _InfoLine(
        icon: Icons.phone_android_rounded,
        text: 'You can leave this screen. It keeps downloading, with progress in your notifications.',
      ),
      const SizedBox(height: 16),
      _SecondButton(label: 'Hide', onTap: () => Navigator.maybePop(context)),
      TextButton(
        onPressed: () {
          Haptics.remove();
          u.cancel();
        },
        child: const Text('Cancel download'),
      ),
    ]);
  }

  Widget _ready(BuildContext context, Updater u, Release r) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _Shield(
        text: u.checksumVerified
            ? 'Verified: matches ShareBro ${r.version} on GitHub'
            : 'Size matches ShareBro ${r.version} on GitHub',
      ),
      const SizedBox(height: 14),
      if (needsPermission) ...[
        const _Permission(),
        const SizedBox(height: 14),
        _MainButton(label: 'Open settings', icon: Icons.settings_rounded, onTap: Updater.allowInstall),
      ] else ...[
        const _InfoLine(
          icon: Icons.verified_user_rounded,
          text: 'Android will ask you to confirm. Your people, names and settings stay.',
        ),
        const SizedBox(height: 16),
        _MainButton(label: 'Install update', icon: Icons.install_mobile_rounded, onTap: onInstall),
      ],
      const SizedBox(height: 8),
      _SecondButton(label: 'Install later', onTap: () => Navigator.maybePop(context)),
    ]);
  }

  Widget _failed(BuildContext context, Updater u) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _ErrorBox(
        text: u.error ?? 'The download stopped.',
        icon: u.badFile ? Icons.gpp_bad_rounded : Icons.wifi_off_rounded,
      ),
      const SizedBox(height: 16),
      _MainButton(label: 'Retry', icon: Icons.refresh_rounded, onTap: u.retry),
      const SizedBox(height: 8),
      _SecondButton(label: 'Later', onTap: () => Navigator.maybePop(context)),
    ]);
  }

  static String _left(Duration d) =>
      d.inMinutes >= 1 ? 'about ${d.inMinutes} min left' : 'about ${math.max(1, d.inSeconds)} s left';
}

/// The app icon inside a ring that fills as it downloads, spins while it's
/// checked, and gets a green tick when it's ready.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.title,
    required this.ring,
    required this.progress,
    required this.done,
    required this.from,
    required this.to,
    required this.meta,
  });

  final String title;
  final _RingMode ring;
  final double progress;
  final bool done;
  final String from, to, meta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _IconRing(mode: ring, progress: progress, done: done),
      const SizedBox(height: 12),
      AnimatedSwitcher(
        duration: _d(context, 220),
        child: Text(
          title,
          key: ValueKey(title),
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3),
        ),
      ),
      const SizedBox(height: 4),
      Semantics(
        label: 'From version $from to $to',
        excludeSemantics: true,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(from, style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.onSurfaceVariant),
          ),
          Text(to, style: TextStyle(fontWeight: FontWeight.w800, color: scheme.primary)),
        ]),
      ),
      const SizedBox(height: 2),
      Text(meta, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
    ]);
  }
}

enum _RingMode { none, progress, spin, full }

class _IconRing extends StatefulWidget {
  const _IconRing({required this.mode, this.progress = 0, this.done = false, this.icon});

  final _RingMode mode;
  final double progress;
  final bool done;

  /// In place of the app icon.
  final Widget? icon;

  @override
  State<_IconRing> createState() => _IconRingState();
}

class _IconRingState extends State<_IconRing> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_IconRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final spin = widget.mode == _RingMode.spin && !MediaQuery.disableAnimationsOf(context);
    if (spin && !_spin.isAnimating) _spin.repeat();
    if (!spin && _spin.isAnimating) _spin.stop();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = switch (widget.mode) {
      _RingMode.none => 0.0,
      _RingMode.progress => widget.progress,
      _RingMode.spin => 0.28,
      _RingMode.full => 1.0,
    };
    return Semantics(
      label: widget.mode == _RingMode.progress ? '${(widget.progress * 100).round()} percent downloaded' : null,
      child: SizedBox.square(
        dimension: 112,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: target),
              duration: _d(context, widget.mode == _RingMode.progress ? 300 : 500),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => AnimatedBuilder(
                animation: _spin,
                builder: (context, _) => CustomPaint(
                  painter: _RingPainter(
                    value: v,
                    rotation: widget.mode == _RingMode.spin ? _spin.value : 0,
                    track: scheme.onSurface.withAlpha(24),
                    color: scheme.primary,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: widget.icon ??
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 18, offset: Offset(0, 8))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset('assets/icon/app_icon_1024.png', fit: BoxFit.cover),
                    ),
                  ),
            ),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: AnimatedScale(
              scale: widget.done ? 1 : 0,
              duration: _d(context, widget.done ? 650 : 200),
              curve: widget.done ? Curves.elasticOut : Curves.easeIn,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Brand.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: Theme.of(context).colorScheme.surfaceContainerLow, width: 3),
                ),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 22),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.value, required this.rotation, required this.track, required this.color});

  final double value, rotation;
  final Color track, color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = Offset.zero & size;
    final circle = rect.deflate(stroke / 2);
    canvas.drawArc(
      circle,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    canvas.drawArc(
      circle,
      -math.pi / 2 + rotation * math.pi * 2,
      math.pi * 2 * value.clamp(0, 1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.rotation != rotation || old.color != color || old.track != track;
}

/// "What's new", one point at a time.
class _Notes extends StatelessWidget {
  const _Notes({required this.release});

  final Release release;

  static const _icons = [
    Icons.auto_awesome_rounded,
    Icons.bolt_rounded,
    Icons.place_rounded,
    Icons.build_rounded,
    Icons.favorite_rounded,
    Icons.tune_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final still = MediaQuery.disableAnimationsOf(context);
    final notes = release.notes;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: scheme.onSurface.withAlpha(10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            "WHAT'S NEW",
            style: TextStyle(
              fontSize: 12,
              letterSpacing: 0.9,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (notes.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(release.summary, style: const TextStyle(fontSize: 14.5, height: 1.35)),
            ),
          for (final (i, n) in notes.indexed)
            _note(context, n, _icons[i % _icons.length])
                .animate(delay: (still ? 0 : 60 * i).ms)
                .fadeIn(duration: (still ? 0 : 320).ms)
                .moveY(begin: still ? 0 : 8, end: 0, duration: (still ? 0 : 320).ms, curve: Curves.easeOutCubic),
        ]),
      ),
    );
  }

  Widget _note(BuildContext context, ReleaseNote n, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(color: scheme.primary.withAlpha(30), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: scheme.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              if (n.title.isNotEmpty)
                TextSpan(
                  text: n.text.isEmpty ? n.title : '${n.title}. ',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              TextSpan(text: n.text, style: TextStyle(color: scheme.onSurfaceVariant)),
            ]),
            style: const TextStyle(fontSize: 14.5, height: 1.35),
          ),
        ),
      ]),
    );
  }
}

/// The green "it's genuine" line; grey with a spinner while it's checked.
class _Shield extends StatelessWidget {
  const _Shield({required this.text, this.busy = false});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = busy ? scheme.onSurfaceVariant : Brand.success;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: busy ? scheme.onSurface.withAlpha(10) : Brand.success.withAlpha(28),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        if (busy)
          SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: color))
        else
          Icon(Icons.verified_user_rounded, color: color, size: 22)
              .animate()
              .scaleXY(begin: 0.4, end: 1, duration: _d(context, 450), curve: Curves.easeOutBack),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: busy ? scheme.onSurfaceVariant : Theme.of(context).brightness == Brightness.dark ? const Color(0xFF5BD69E) : const Color(0xFF137A50),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Permission extends StatelessWidget {
  const _Permission();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.primary.withAlpha(22), borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.admin_panel_settings_rounded, color: scheme.primary),
        const SizedBox(width: 12),
        const Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: 'One step, once. ', style: TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(
                text: 'Android needs your OK for ShareBro to install updates. '
                    'Turn on "Allow from this source", then come back.',
              ),
            ]),
            style: TextStyle(fontSize: 14, height: 1.35),
          ),
        ),
      ]),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.text, this.icon = Icons.wifi_off_rounded});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.error.withAlpha(26), borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: scheme.error, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 14, height: 1.35, fontWeight: FontWeight.w600, color: scheme.onSurface)),
        ),
      ]),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: scheme.onSurfaceVariant),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: TextStyle(fontSize: 13.5, height: 1.35, color: scheme.onSurfaceVariant))),
    ]);
  }
}

class _MainButton extends StatelessWidget {
  const _MainButton({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          onPressed: onTap,
          icon: Icon(icon),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );
}

class _SecondButton extends StatelessWidget {
  const _SecondButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton.tonal(
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
        ),
      );
}

// ---- Checking, up to date, couldn't check ----

class _Checking extends StatelessWidget {
  const _Checking({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const _IconRing(mode: _RingMode.spin),
        const SizedBox(height: 14),
        Text('Checking for updates…',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Asking GitHub for the latest version', style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _UpToDate extends StatelessWidget {
  const _UpToDate({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final checked = Updater.instance.checkedAt;
    final when = checked == null
        ? ''
        : DateTime.now().difference(checked).inMinutes < 2
            ? ' · checked just now'
            : ' · checked ${releasedAgo(checked, DateTime.now())}';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(color: Brand.success.withAlpha(30), shape: BoxShape.circle),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: _d(context, 700),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => CustomPaint(painter: _TickPainter(t)),
        ),
      ).animate().scaleXY(begin: 0.6, end: 1, duration: _d(context, 500), curve: Curves.easeOutBack),
      const SizedBox(height: 14),
      Text("You're up to date", style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(
        'ShareBro $version is the latest version$when',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 22),
      _SecondButton(label: 'Done', onTap: () => Navigator.maybePop(context)),
    ]);
  }
}

/// A tick that draws itself.
class _TickPainter extends CustomPainter {
  _TickPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final path = Path()
      ..moveTo(6.5 * s, 12.5 * s)
      ..lineTo(10.5 * s, 16.5 * s)
      ..lineTo(18 * s, 8 * s);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Brand.success;
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.t != t;
}

class _CheckFailed extends StatelessWidget {
  const _CheckFailed({super.key, required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _IconRing(
        mode: _RingMode.none,
        icon: Icon(Icons.cloud_off_rounded, size: 46, color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      Text("Couldn't check for updates",
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 14),
      _ErrorBox(text: error),
      const SizedBox(height: 16),
      _MainButton(label: 'Try again', icon: Icons.refresh_rounded, onTap: onRetry),
      const SizedBox(height: 8),
      _SecondButton(label: 'Close', onTap: () => Navigator.maybePop(context)),
    ]);
  }
}
