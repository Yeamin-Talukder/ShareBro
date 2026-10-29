import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/apps.dart';
import '../data/dates.dart';
import 'motion.dart';
import 'widgets.dart';

/// Pick installed apps to send. Returns what to send (one APK per app, or a
/// folder of parts for apps installed from app bundles).
class AppPickerScreen extends StatefulWidget {
  const AppPickerScreen({super.key});

  @override
  State<AppPickerScreen> createState() => _AppPickerScreenState();
}

class _AppPickerScreenState extends State<AppPickerScreen> {
  List<InstalledApp>? _apps;
  bool _system = false;
  String _query = '';
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _apps = null);
    final apps = await Apps.list(system: _system);
    if (mounted) setState(() => _apps = apps);
  }

  List<InstalledApp> get _shown {
    final q = _query.trim().toLowerCase();
    final all = _apps ?? const <InstalledApp>[];
    return q.isEmpty
        ? all
        : [for (final a in all) if (a.name.toLowerCase().contains(q) || a.package.contains(q)) a];
  }

  void _toggle(InstalledApp a) {
    Haptics.tick();
    setState(() => _picked.contains(a.package) ? _picked.remove(a.package) : _picked.add(a.package));
  }

  void _done() {
    final chosen = [for (final a in _apps ?? const <InstalledApp>[]) if (_picked.contains(a.package)) a];
    Navigator.pop(context, [for (final a in chosen) ...a.toSendItems()]);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final apps = _apps;
    final shown = _shown;
    final pickedSize = [
      for (final a in apps ?? const <InstalledApp>[])
        if (_picked.contains(a.package)) a.size,
    ].fold<int>(0, (n, s) => n + s);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose apps'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) {
              _system = !_system;
              _load();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'system', checked: _system, child: const Text('Show built-in apps')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              hintText: 'Search apps',
              leading: const Icon(Icons.search_rounded),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ),
      ),
      body: apps == null
          ? const Center(child: CircularProgressIndicator())
          : apps.isEmpty
              ? const EmptyIllustration(message: 'No apps to send.')
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 110),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final a = shown[i];
                    final picked = _picked.contains(a.package);
                    return ListTile(
                      onTap: () => _toggle(a),
                      leading: _AppIcon(package: a.package),
                      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          if (a.version.isNotEmpty) 'v${a.version}',
                          formatBytes(a.size),
                          if (a.isSplit) '${a.files.length} parts',
                        ].join(' · '),
                        style: text.bodySmall,
                      ),
                      trailing: AnimatedSwitcher(
                        duration: 180.ms,
                        transitionBuilder: (c, an) => ScaleTransition(scale: an, child: c),
                        child: Icon(
                          picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                          key: ValueKey(picked),
                          color: picked ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ).animate().fadeIn(delay: (12 * i.clamp(0, 25)).ms, duration: 200.ms);
                  },
                ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _picked.isEmpty
          ? null
          : FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(240, 54)),
              onPressed: _done,
              icon: const Icon(Icons.add_rounded),
              label: Text('Add ${_picked.length} ${_picked.length == 1 ? 'app' : 'apps'} · ${formatBytes(pickedSize)}'),
            ).animate().fadeIn().moveY(begin: 20, curve: Curves.easeOutBack),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.package});

  final String package;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 44,
      child: FutureBuilder<Uint8List?>(
        future: Apps.icon(package),
        builder: (context, snap) => snap.data == null
            ? Icon(Icons.android_rounded, color: Theme.of(context).colorScheme.outline)
            : Image.memory(snap.data!, gaplessPlayback: true),
      ),
    );
  }
}
