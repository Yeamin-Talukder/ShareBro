import 'dart:async';

import 'package:flutter/material.dart';

import '../update/release.dart';
import 'glass.dart';
import 'island.dart' show islandNavigator;
import 'motion.dart';
import 'update_sheet.dart';

/// "ShareBro 1.5.0 is here": slides down from the top once when the daily
/// check finds a new version. Tap to see what's new, swipe up to dismiss;
/// it goes by itself after a few seconds.
class UpdateBanner {
  static OverlayEntry? _entry;

  static void show(Release r) {
    final overlay = islandNavigator.currentState?.overlay;
    if (overlay == null) return;
    _entry?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _Banner(
        release: r,
        onGone: () {
          if (_entry == entry) _entry = null;
          entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }
}

class _Banner extends StatefulWidget {
  const _Banner({required this.release, required this.onGone});

  final Release release;
  final VoidCallback onGone;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
    reverseDuration: const Duration(milliseconds: 260),
  );
  Timer? _auto;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _a.forward();
    Haptics.tick();
    _auto = Timer(const Duration(seconds: 8), _hide);
  }

  @override
  void dispose() {
    _auto?.cancel();
    _a.dispose();
    super.dispose();
  }

  Future<void> _hide() async {
    if (_leaving) return;
    _leaving = true;
    _auto?.cancel();
    await _a.reverse();
    widget.onGone();
  }

  void _open() {
    final nav = islandNavigator.currentState;
    _hide();
    if (nav != null) showUpdateSheet(nav.context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = widget.release;
    final first = r.notes.isEmpty ? null : r.notes.first;
    final line = first == null
        ? 'Tap to see what\'s new'
        : '${first.title.isNotEmpty ? first.title : first.text}${r.notes.length > 1 ? ', and more' : ''}';
    final still = MediaQuery.disableAnimationsOf(context);
    final curve = CurvedAnimation(parent: _a, curve: const Cubic(0.2, 1.2, 0.4, 1), reverseCurve: Curves.easeIn);
    return Positioned(
      top: MediaQuery.viewPaddingOf(context).top + 8,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: still
            ? const AlwaysStoppedAnimation(Offset.zero)
            : Tween(begin: const Offset(0, -1.6), end: Offset.zero).animate(curve),
        child: FadeTransition(
          opacity: _a,
          child: GestureDetector(
            onTap: _open,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -100) _hide();
            },
            child: Semantics(
              button: true,
              label: 'ShareBro ${r.version} is here. $line. See what\'s new',
              excludeSemantics: true,
              child: Glass(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                child: Material(
                  type: MaterialType.transparency,
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/icon/app_icon_1024.png', width: 42, height: 42),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(
                          'ShareBro ${r.version} is here',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, height: 1.3, color: scheme.onSurfaceVariant),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _open,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        minimumSize: const Size(0, 40),
                      ),
                      child: const Text('See what\'s new', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
