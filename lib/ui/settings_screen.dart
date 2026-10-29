import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/backup.dart';
import '../data/db.dart';
import '../scan/scan_controller.dart';
import '../share/native_files.dart';
import '../share/net.dart';
import '../share/prepare.dart';
import 'app_lock.dart';
import 'island.dart';
import 'storage_screen.dart';
import 'aurora.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ScanController get c => widget.controller;
  late double _value = c.strictness;
  int? _preview;
  int? _current;
  bool _previewing = false;
  bool _applying = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    c.previewStrictness(c.strictness).then((n) {
      if (mounted) setState(() => _current = _preview = n);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onSlide(double v) {
    setState(() {
      _value = v;
      _previewing = true;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final n = await c.previewStrictness(v);
      if (mounted && v == _value) {
        setState(() {
          _preview = n;
          _previewing = false;
        });
      }
    });
  }

  Future<void> _apply() async {
    setState(() => _applying = true);
    await c.setStrictness(_value);
    if (!mounted) return;
    setState(() {
      _applying = false;
      _current = _preview;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Faces regrouped')));
  }

  Future<void> _renameDevice() async {
    final text = TextEditingController(text: c.sharing.identity.alias);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name on other phones'),
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Rayhan\'s camera'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    await ShareIdentity.setAlias(c.db, name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved — friends will see the new name after the app restarts')));
  }

  Future<void> _pickQuality() async {
    final q = await showModalBottomSheet<SendQuality>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (q, title, sub) in [
            (SendQuality.original, 'Original', 'Full quality, exactly as taken'),
            (SendQuality.noLocation, 'Original without location', 'Removes GPS and camera details'),
            (SendQuality.smaller, 'Smaller', 'Up to 2048 px — quicker to send'),
          ])
            ListTile(
              title: Text(title),
              subtitle: Text(sub),
              trailing: c.sharing.defaultQuality == q ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, q),
            ),
        ]),
      ),
    );
    if (q == null) return;
    await c.sharing.setDefaultQuality(q);
    setState(() {});
  }

  Future<void> _backup() async {
    final file = await makeBackup();
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'ShareBro backup — contains face data, keep it private.',
      ),
    );
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose a backup file',
    );
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null || !mounted) return;
    final file = File(path);
    if (!await isBackup(file)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That file isn\'t a ShareBro backup.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.settings_backup_restore),
        title: const Text('Restore this backup?'),
        content: const Text(
          'Everything in the app now (names, groups, trips) is replaced. '
          'Your photos are not touched. The app closes afterwards; open it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.db.close();
    await restoreBackup(file);
    await SystemNavigator.pop();
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Clear all face data?'),
        content: const Text(
          'Your photos are not touched. Only the app\'s trips, face groups and names are removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.db.clearAll();
    c.changed();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final changed = (_value - c.strictness).abs() > 0.001;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Grouping strictness',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Loose puts more faces together (may mix people up). '
                      'Strict keeps groups clean (may split one person into several).',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    Slider(
                      value: _value,
                      divisions: 20,
                      onChanged: _applying || c.running ? null : _onSlide,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Text('Loose', style: text.labelMedium),
                          const Spacer(),
                          Text('Strict', style: text.labelMedium),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: AnimatedSwitcher(
                        duration: 250.ms,
                        transitionBuilder: (child, a) => ScaleTransition(
                          scale: a,
                          child: FadeTransition(opacity: a, child: child),
                        ),
                        child: _preview == null || _previewing
                            ? const SizedBox(
                                key: ValueKey('busy'),
                                height: 56,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : Column(
                                key: ValueKey(_preview),
                                children: [
                                  Text(
                                    '≈ $_preview people',
                                    style: text.headlineMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: scheme.primary,
                                    ),
                                  ),
                                  if (_current != null && _preview != _current)
                                    Text(
                                      'now $_current',
                                      style: text.bodySmall,
                                    ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    AnimatedSize(
                      duration: 250.ms,
                      child: changed
                          ? SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _applying ? null : _apply,
                                icon: _applying
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.auto_fix_high),
                                label: const Text('Regroup with this setting'),
                              ),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Named people and faces you fixed by hand are never changed.',
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Name on other phones'),
              subtitle: Text(c.sharing.identity.alias),
              onTap: _renameDevice,
            ),
            ListTile(
              leading: const Icon(Icons.high_quality_outlined),
              title: const Text('Default send quality'),
              subtitle: Text(switch (c.sharing.defaultQuality) {
                SendQuality.original => 'Original',
                SendQuality.noLocation => 'Original without location',
                SendQuality.smaller => 'Smaller (2048 px)',
              }),
              onTap: _pickQuality,
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.autorenew),
                    title: const Text('Auto-scan new photos'),
                    subtitle: const Text(
                      'When a scanned album gets new photos, scan just those',
                    ),
                    value: c.autoScanEnabled,
                    onChanged: (v) async {
                      await c.setAutoScan(v);
                      setState(() {});
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.lock_outline),
                    title: const Text('App lock'),
                    subtitle: const Text(
                      'Fingerprint, face or screen lock to open the app',
                    ),
                    value: c.appLock,
                    onChanged: (v) async {
                      // Prove it's you before turning the lock on or off.
                      if (!await confirmOwner(
                        v ? 'Turn on app lock' : 'Turn off app lock',
                      )) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Set up a screen lock on the phone first.',
                            ),
                          ),
                        );
                        return;
                      }
                      await c.setAppLock(v);
                      setState(() {});
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.horizontal_rule_rounded),
                    title: const Text('Island at the top'),
                    subtitle: const Text(
                      'Shows sending, receiving, scanning and requests in a pill. '
                      'Off: requests ask in a popup, messages show at the bottom',
                    ),
                    value: Island.enabled.value,
                    onChanged: (v) async {
                      await Island.setEnabled(c.db, v);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.pie_chart_outline),
                    title: const Text('Storage'),
                    subtitle: const Text(
                      'Space used by trips, duplicates and screenshots',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StorageScreen(controller: c),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.person_off_outlined),
                    title: const Text('Not in our group'),
                    subtitle: const Text('People you hid, to bring back'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _IgnoredScreen(controller: c),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.backup_outlined),
                    title: const Text('Back up'),
                    subtitle: const Text(
                      'Names, faces, trips and groups to one file (not the photos)',
                    ),
                    onTap: c.running ? null : _backup,
                  ),
                  ListTile(
                    leading: const Icon(Icons.settings_backup_restore),
                    title: const Text('Restore from backup'),
                    subtitle: const Text('Replaces what\'s in the app now'),
                    onTap: c.running ? null : _restore,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Clear all face data'),
                subtitle: const Text('Photos are not affected'),
                onTap: c.running ? null : _confirmClear,
              ),
            ),
            const SizedBox(height: 16),
            const _AboutCard(),
          ],
        ),
      ),
    );
  }
}

/// Who made ShareBro, with links to the developer's GitHub and the code.
class _AboutCard extends StatelessWidget {
  const _AboutCard();

  static const _profile = 'https://github.com/Yeamin-Talukder';
  static const _repo = 'https://github.com/Yeamin-Talukder/ShareBro';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset('assets/icon/app_icon_1024.png', width: 52, height: 52),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ShareBro', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text('Made by Md Yeamin Talukder', style: text.bodyMedium),
              ]),
            ),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline_rounded),
          title: const Text('Developer'),
          subtitle: const Text('github.com/Yeamin-Talukder'),
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => NativeFiles.open(_profile),
        ),
        ListTile(
          leading: const Icon(Icons.code_rounded),
          title: const Text('Source code'),
          subtitle: const Text('github.com/Yeamin-Talukder/ShareBro'),
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => NativeFiles.open(_repo),
        ),
      ]),
    );
  }
}

/// People marked "Not in our group", with a way back.
class _IgnoredScreen extends StatefulWidget {
  const _IgnoredScreen({required this.controller});

  final ScanController controller;

  @override
  State<_IgnoredScreen> createState() => _IgnoredScreenState();
}

class _IgnoredScreenState extends State<_IgnoredScreen> {
  List<PersonSummary>? _people;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final people = await widget.controller.db.people(ignored: true);
    if (mounted) setState(() => _people = people);
  }

  @override
  Widget build(BuildContext context) {
    final people = _people;
    return Scaffold(
      appBar: AppBar(title: const Text('Not in our group')),
      body: people == null
          ? const Center(child: CircularProgressIndicator())
          : people.isEmpty
          ? const EmptyIllustration(
              message:
                  'Nobody hidden.\nOn a person\'s page, use ⋮ → "Not in our group" '
                  'for strangers in the background.',
            )
          : ListView(
              children: [
                for (final p in people)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundImage: p.coverThumb == null
                          ? null
                          : MemoryImage(p.coverThumb!),
                    ),
                    title: Text(p.displayName),
                    subtitle: Text('${p.photoCount} photos'),
                    trailing: TextButton(
                      onPressed: () async {
                        await widget.controller.db.setIgnored(p.id, false);
                        widget.controller.changed();
                        await _load();
                      },
                      child: const Text('Bring back'),
                    ),
                  ),
              ],
            ),
    );
  }
}
