import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/backup.dart';
import '../data/db.dart';
import '../face/accel.dart';
import '../scan/scan_controller.dart';
import '../share/native_files.dart';
import '../share/net.dart';
import '../share/prepare.dart';
import '../update/updater.dart';
import 'app_lock.dart';
import 'island.dart';
import 'profile_screen.dart';
import 'sections.dart';
import 'storage_screen.dart';
import 'theme.dart';
import 'update_sheet.dart';
import 'aurora.dart';
import 'glass.dart';
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
    _loadChips();
  }

  /// What scanning has learned about this phone's chips so far.
  AccelState? _chips;

  Future<void> _loadChips() async {
    final chips = await c.faceChips();
    if (mounted) setState(() => _chips = chips);
  }

  /// "12 ms a face", "didn't work on this phone", or nothing yet.
  String? _chipNote(Accel chip) {
    final chips = _chips;
    if (chips == null) return null;
    if (chips.bad.contains(chip)) return "didn't work on this phone";
    final ms = chips.ms[chip];
    if (ms == null) return null;
    return '${ms < 10 ? ms.toStringAsFixed(1) : ms.round()} ms a face';
  }

  String get _chipSummary {
    final chips = _chips;
    final only = c.faceChip.only;
    if (only == null) {
      final measured = chips != null && chips.ms.length > 1;
      return measured ? 'Automatic · ${chips.best.label} is fastest on this phone' : 'Automatic · picks the fastest chip that works';
    }
    if (chips != null && chips.bad.contains(only)) return "${only.label} didn't work on this phone · using the CPU";
    return 'Always the ${only.label}';
  }

  Future<void> _pickChip() async {
    final picked = await showModalBottomSheet<AccelChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (choice, title, sub) in [
            (AccelChoice.auto, 'Automatic', 'Tries each chip once and keeps the fastest that works'),
            (AccelChoice.cpu, 'CPU', 'The main processor. Works on every phone'),
            (AccelChoice.gpu, 'GPU', 'The graphics chip'),
            (AccelChoice.npu, 'NPU', 'The neural chip, on phones that have one'),
          ])
            ListTile(
              title: Text(title),
              subtitle: Text([sub, if (choice.only case final chip?) ?_chipNote(chip)].join(' · ')),
              trailing: c.faceChip == choice ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, choice),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    await c.setFaceChip(picked);
    await _loadChips();
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
    Future<void> setLock(bool v) async {
      // Prove it's you before turning the lock on or off.
      if (!await confirmOwner(v ? 'Turn on app lock' : 'Turn off app lock')) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Set up a screen lock on the phone first.')),
        );
        return;
      }
      await c.setAppLock(v);
      setState(() {});
    }

    Future<void> setAutoScan(bool v) async {
      await c.setAutoScan(v);
      setState(() {});
    }

    Future<void> setIsland(bool v) async {
      await Island.setEnabled(c.db, v);
      setState(() {});
    }

    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GlassScrollView(
          title: 'Settings',
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 24),
              sliver: SliverList.list(children: [
                ListenableBuilder(
                  listenable: c,
                  builder: (context, _) => SectionCard(
                    child: SectionRow(
                      leading: CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.surfaceContainerHighest,
                        backgroundImage: c.profile.thumb == null ? null : MemoryImage(c.profile.thumb!),
                        child: c.profile.thumb == null ? Icon(Icons.face_rounded, color: scheme.onSurfaceVariant) : null,
                      ),
                      title: 'Profile',
                      subtitle: c.profile.isSet ? 'Your face is set · ${c.sharing.identity.alias}' : 'Set up your face for trip groups',
                      chevron: true,
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c))),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Grouping strictness', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'Loose puts more faces together (may mix people up). '
                        'Strict keeps groups clean (may split one person into several).',
                        style: text.bodySmall?.copyWith(fontSize: 13.5, color: scheme.onSurfaceVariant),
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
                            Text('Loose', style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                            const Spacer(),
                            Text('Strict', style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
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
                                  child: Center(child: CircularProgressIndicator()),
                                )
                              : Column(
                                  key: ValueKey(_preview),
                                  children: [
                                    Text(
                                      '≈ $_preview people',
                                      style: text.displaySmall?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: scheme.primary,
                                      ),
                                    ),
                                    if (_current != null && _preview != _current)
                                      Text('now $_current', style: text.bodySmall),
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
                                          child: CircularProgressIndicator(strokeWidth: 2),
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
                        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SectionHeader(title: 'Appearance'),
                SectionCard(
                  padding: const EdgeInsets.all(8),
                  child: ValueListenableBuilder<ThemeMode>(
                    valueListenable: Appearance.mode,
                    builder: (context, mode, _) => CapsuleSwitch<ThemeMode>(
                      value: mode,
                      height: 44,
                      options: const [
                        (ThemeMode.system, 'System', null),
                        (ThemeMode.light, 'Light', null),
                        (ThemeMode.dark, 'Dark', null),
                      ],
                      onChanged: (m) => Appearance.set(c.db, m),
                    ),
                  ),
                ),
                const SectionFooter('System follows your phone\'s dark mode setting.'),
                const SectionHeader(title: 'Sharing'),
                SectionCard.rows(rows: [
                  SectionRow(
                    leading: const IconTile(icon: Icons.badge_rounded, color: Color(0xFF0A84FF)),
                    title: 'Name on other phones',
                    subtitle: c.sharing.identity.alias,
                    chevron: true,
                    onTap: _renameDevice,
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.hd_rounded, color: Color(0xFF5E5CE6)),
                    title: 'Default send quality',
                    subtitle: switch (c.sharing.defaultQuality) {
                      SendQuality.original => 'Original',
                      SendQuality.noLocation => 'Original without location',
                      SendQuality.smaller => 'Smaller (2048 px)',
                    },
                    chevron: true,
                    onTap: _pickQuality,
                  ),
                ]),
                const SectionHeader(title: 'General'),
                SectionCard.rows(rows: [
                  SectionRow(
                    leading: const IconTile(icon: Icons.sync_rounded, color: Color(0xFF30B0C7)),
                    title: 'Auto-scan new photos',
                    subtitle: 'When a scanned album gets new photos, scan just those',
                    trailing: Switch(value: c.autoScanEnabled, onChanged: setAutoScan),
                    onTap: () => setAutoScan(!c.autoScanEnabled),
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.memory_rounded, color: Color(0xFFFF375F)),
                    title: 'Face scanning chip',
                    subtitle: _chipSummary,
                    chevron: true,
                    onTap: _pickChip,
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.lock_rounded, color: Color(0xFF8E8E93)),
                    title: 'App lock',
                    subtitle: 'Fingerprint, face or screen lock to open the app',
                    trailing: Switch(value: c.appLock, onChanged: setLock),
                    onTap: () => setLock(!c.appLock),
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.call_to_action_rounded, color: Color(0xFF48484A)),
                    title: 'Island at the top',
                    subtitle: 'Shows sending, receiving, scanning and requests in a pill. '
                        'Off: requests ask in a popup, messages show at the bottom',
                    trailing: Switch(value: Island.enabled.value, onChanged: setIsland),
                    onTap: () => setIsland(!Island.enabled.value),
                  ),
                ]),
                const SectionHeader(title: 'Your data'),
                SectionCard.rows(rows: [
                  SectionRow(
                    leading: const IconTile(icon: Icons.pie_chart_rounded, color: Color(0xFFFF9F0A)),
                    title: 'Storage',
                    subtitle: 'Space used by trips, duplicates and screenshots',
                    chevron: true,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => StorageScreen(controller: c)),
                    ),
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.person_off_rounded, color: Color(0xFFAF52DE)),
                    title: 'Not in our group',
                    subtitle: 'People you hid, to bring back',
                    chevron: true,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => _IgnoredScreen(controller: c)),
                    ),
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.backup_rounded, color: Color(0xFF34C759)),
                    title: 'Back up',
                    subtitle: 'Names, faces, trips and groups to one file (not the photos)',
                    enabled: !c.running,
                    onTap: _backup,
                  ),
                  SectionRow(
                    leading: const IconTile(icon: Icons.settings_backup_restore_rounded, color: Color(0xFF30B0C7)),
                    title: 'Restore from backup',
                    subtitle: 'Replaces what\'s in the app now',
                    enabled: !c.running,
                    onTap: _restore,
                  ),
                ]),
                const SizedBox(height: 22),
                SectionCard(
                  child: SectionRow(
                    leading: IconTile(icon: Icons.delete_sweep_rounded, color: scheme.error),
                    title: 'Clear all face data',
                    subtitle: 'Photos are not affected',
                    destructive: true,
                    enabled: !c.running,
                    onTap: _confirmClear,
                  ),
                ),
                const SectionHeader(title: 'Updates'),
                ListenableBuilder(
                  listenable: Updater.instance,
                  builder: (context, _) {
                    final u = Updater.instance;
                    return SectionCard.rows(rows: [
                      SectionRow(
                        leading: const IconTile(icon: Icons.update_rounded, color: Color(0xFF34C759)),
                        title: 'Check for updates automatically',
                        subtitle: "Once a day, and tells you when there's a new version",
                        trailing: Switch(value: u.autoCheck, onChanged: u.setAutoCheck),
                        onTap: () => u.setAutoCheck(!u.autoCheck),
                      ),
                      SectionRow(
                        leading: const IconTile(icon: Icons.wifi_rounded, color: Color(0xFF0A84FF)),
                        title: 'Download on Wi-Fi only',
                        subtitle: 'On mobile data, asks first. Updates are about 90 MB',
                        trailing: Switch(value: u.wifiOnly, onChanged: u.setWifiOnly),
                        onTap: () => u.setWifiOnly(!u.wifiOnly),
                      ),
                    ]);
                  },
                ),
                const SectionFooter(
                  "Updates come from ShareBro's releases on GitHub and are checked before they install. "
                  'Only the version check goes online; nothing about you or your photos is sent.',
                ),
                const SectionHeader(title: 'About'),
                const _AboutCard(),
              ]),
            ),
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
    return SectionCard(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
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
        const Divider(height: 0.5, thickness: 0.5, indent: 16),
        const _UpdateRow(),
        const Divider(height: 0.5, thickness: 0.5, indent: 62),
        SectionRow(
          leading: const IconTile(icon: Icons.person_rounded, color: Color(0xFF636366)),
          title: 'Developer',
          subtitle: 'github.com/Yeamin-Talukder',
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => NativeFiles.open(_profile),
        ),
        const Divider(height: 0.5, thickness: 0.5, indent: 62),
        SectionRow(
          leading: const IconTile(icon: Icons.code_rounded, color: Color(0xFF636366)),
          title: 'Source code',
          subtitle: 'github.com/Yeamin-Talukder/ShareBro',
          trailing: const Icon(Icons.open_in_new_rounded, size: 18),
          onTap: () => NativeFiles.open(_repo),
        ),
      ]),
    );
  }
}

/// "Software update": the version, what's happening, and a NEW badge.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Updater.instance,
      builder: (context, _) {
        final u = Updater.instance;
        final next = u.release?.version.toString();
        final subtitle = switch (u.stage) {
          UpdateStage.checking => 'Checking for updates…',
          UpdateStage.available => 'Version $next is available',
          UpdateStage.downloading => 'Downloading $next · ${(u.progress * 100).round()}%',
          UpdateStage.verifying => 'Checking the download…',
          UpdateStage.ready => 'Version $next is ready to install',
          UpdateStage.failed when u.release != null && u.apk != null => 'Download paused · tap to retry',
          _ => 'Version ${u.currentText}',
        };
        final Widget trailing;
        if (u.stage == UpdateStage.available || u.stage == UpdateStage.ready) {
          trailing = const _NewBadge();
        } else if (u.stage == UpdateStage.downloading) {
          trailing = SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(value: u.progress, strokeWidth: 3, strokeCap: StrokeCap.round),
          );
        } else if (u.busy) {
          trailing = const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2.4));
        } else {
          trailing = const SizedBox.shrink();
        }
        return SectionRow(
          leading: const IconTile(icon: Icons.system_update_rounded, color: Brand.accentLight),
          title: 'Software update',
          subtitle: subtitle,
          trailing: trailing,
          chevron: true,
          onTap: () => showUpdateSheet(context, check: true),
        );
      },
    );
  }
}

/// A coral "NEW" pill that gently pulses.
class _NewBadge extends StatelessWidget {
  const _NewBadge();

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: Brand.accentLight, borderRadius: BorderRadius.circular(99)),
      child: const Text(
        'NEW',
        style: TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) return badge;
    return badge
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scaleXY(begin: 1, end: 1.08, duration: 900.ms, curve: Curves.easeInOut);
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
