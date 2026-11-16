import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'island.dart' show islandNavigator;
import 'theme.dart';

/// Keys and mouse buttons that work on every desktop page: back (Esc,
/// Alt + Left, the mouse's Back button) and the shortcuts sheet (F1 or
/// Ctrl + /). Wraps the whole app on desktop.
class DesktopKeys extends StatefulWidget {
  const DesktopKeys({super.key, required this.child});

  final Widget child;

  /// Things that use Esc themselves right now (a grid with a selection
  /// clears it first), so Esc doesn't also close the page.
  static final Set<Object> escClaims = {};

  @override
  State<DesktopKeys> createState() => _DesktopKeysState();
}

class _DesktopKeysState extends State<DesktopKeys> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  bool _typing() {
    final w = FocusManager.instance.primaryFocus?.context?.widget;
    return w is EditableText;
  }

  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    final keys = HardwareKeyboard.instance;
    if (k == LogicalKeyboardKey.f1 || (k == LogicalKeyboardKey.slash && keys.isControlPressed)) {
      final context = islandNavigator.currentContext;
      if (context != null && !_sheetOpen) showShortcuts(context);
      return true;
    }
    final back = (k == LogicalKeyboardKey.arrowLeft && keys.isAltPressed) ||
        (k == LogicalKeyboardKey.escape && DesktopKeys.escClaims.isEmpty && !keys.isControlPressed);
    if (!back) return false;
    // Esc in a text box clears or closes that box first (its own job).
    if (k == LogicalKeyboardKey.escape && _typing()) return false;
    _back();
    // Esc also reaches dialogs and menus, which close themselves.
    return k != LogicalKeyboardKey.escape;
  }

  void _back() {
    final nav = islandNavigator.currentState;
    // Dialogs, sheets and menus handle Esc on their own; only pages go back.
    if (nav == null || !nav.canPop()) return;
    var top = true;
    nav.popUntil((route) {
      top = route is PageRoute;
      return true;
    });
    if (top) nav.maybePop();
  }

  @override
  Widget build(BuildContext context) => Listener(
        // The Back button on the side of a mouse.
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse && e.buttons & kBackMouseButton != 0) _back();
        },
        child: widget.child,
      );
}

bool _sheetOpen = false;

/// Every keyboard and touchpad control, in one sheet (F1 or Ctrl + /).
Future<void> showShortcuts(BuildContext context) async {
  _sheetOpen = true;
  try {
    await showDialog<void>(context: context, builder: (_) => const _ShortcutsDialog());
  } finally {
    _sheetOpen = false;
  }
}

const _groups = <(String, List<(String, String)>)>[
  ('Anywhere', [
    ('Ctrl  K', 'Search'),
    ('Ctrl  1 – 4', 'People, Photos, Explore, Share'),
    ('Ctrl  ,', 'Settings'),
    ('Ctrl  O', 'Add a folder of photos'),
    ('Esc  ·  Alt  ←  ·  mouse Back', 'Go back'),
    ('F1  ·  Ctrl  /', 'This list'),
  ]),
  ('Photos', [
    ('← → ↑ ↓', 'Move between photos'),
    ('Enter', 'Open'),
    ('Space', 'Select'),
    ('Shift  click  ·  Shift  arrows', 'Select a range'),
    ('Ctrl  click', 'Add to the selection'),
    ('Ctrl  A', 'Select all'),
    ('Delete', 'Move to the Recycle Bin'),
    ('Right-click', 'More actions'),
    ('Pinch  ·  Ctrl  wheel  ·  Ctrl  + / −', 'Bigger or smaller photos'),
    ('Home  ·  End  ·  Page Up / Down', 'Jump through the list'),
  ]),
  ('Viewing a photo', [
    ('← →  ·  two-finger swipe', 'Previous or next'),
    ('Home  ·  End', 'First or last'),
    ('Pinch  ·  wheel  ·  +  −  0', 'Zoom in, out, fit'),
    ('Double-click', 'Zoom to that spot'),
    ('I', 'Details'),
    ('F', 'Show faces'),
    ('Delete', 'Move to the Recycle Bin'),
    ('Esc', 'Close'),
  ]),
  ('Reviewing faces', [
    ('←', 'No / Different'),
    ('→', 'Yes / Same'),
  ]),
];

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 12, 4),
            child: Row(children: [
              const Expanded(
                child: Text('Keyboard and touchpad',
                    style: TextStyle(fontSize: TextSize.title3, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                tooltip: 'Close (Esc)',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(24, 0, 24, 20), children: [
              for (final (title, rows) in _groups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 6),
                  child: Text(title.toUpperCase(),
                      style: TextStyle(
                          fontSize: TextSize.tiny,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: scheme.onSurfaceVariant)),
                ),
                for (final (keys, what) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 250,
                        child: Wrap(spacing: 4, runSpacing: 4, children: [
                          for (final part in keys.split('  ')) _Key(part),
                        ]),
                      ),
                      Expanded(child: Text(what, style: const TextStyle(fontSize: TextSize.label))),
                    ]),
                  ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One key cap ("Ctrl"), or a joining word (" · ") as plain text.
class _Key extends StatelessWidget {
  const _Key(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (label == '·' || label == 'click' || label == 'wheel' || label == 'arrows' || label.contains('swipe') ||
        label == 'Pinch' || label == 'Right-click' || label == 'Double-click' || label.startsWith('mouse')) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(label, style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(label, style: const TextStyle(fontSize: TextSize.small, fontWeight: FontWeight.w600)),
    );
  }
}
