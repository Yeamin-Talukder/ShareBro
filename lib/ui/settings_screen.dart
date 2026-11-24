import 'dart:async';

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'anim.dart';

import '../data/backup.dart';
import '../data/db.dart';
import '../face/accel.dart';
import '../platform/device.dart';
import '../scan/scan_controller.dart';
import '../share/native_files.dart';
import '../share/net.dart';
import '../share/prepare.dart';
import '../share/receive.dart';
import '../update/updater.dart';
import 'app_lock.dart';
import 'desktop_layout.dart';
import 'island.dart';
import 'profile_screen.dart';
import 'sections.dart';
import 'scan_helper_ui.dart';
import 'software_update.dart';
import 'storage_screen.dart';
import 'theme.dart';
import 'update_sheet.dart';
import 'aurora.dart';
import 'glass.dart';
import 'widgets.dart';
import 'face_image.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller, this.section});

  final ScanController controller;

  /// On a computer, the section to show first: 'profile', 'grouping',
  /// 'appearance', 'sharing', 'general', 'data', 'updates' or 'about'.
  final String? section;

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
    NativeFiles.androidSdk().then((v) {
      if (mounted) setState(() => _sdk = v);
    });
  }

  /// Android's version (0 elsewhere): Android 9 can't put received photos
  /// in a chosen folder.
  int _sdk = 0;

  Receiver get _receiver => c.sharing.receiver;

  /// Computer: pick the folder received files are saved in.
  Future<void> _pickDesktopFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose where received files are saved',
      initialDirectory: await _receiver.desktopTarget(),
    );
    if (path == null) return;
    await _receiver.setDesktopFolder(path);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Received files will be saved to $path')));
  }

  Future<void> _openDesktopFolder() async {
    final folder = Directory(await _receiver.desktopTarget());
    await folder.create(recursive: true);
    await NativeFiles.open(folder.path);
  }

  /// Phone: where received photos and videos ([media]) or other files go:
  /// a folder from the system picker, or back to the default.
  Future<void> _pickPhoneFolder({required bool media}) async {
    final current = media ? _receiver.mediaFolder : _receiver.filesFolder;
    final fallback = media ? defaultMediaFolder : defaultFilesFolder;
    final roots = media ? mediaRoots : filesRoots;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: const Text('Choose a folder…'),
            subtitle: Text('Inside ${roots.join(' or ')}. You can make a new folder in the picker'),
            onTap: () => Navigator.pop(context, 'pick'),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt_rounded),
            title: Text(fallback),
            subtitle: Text(media ? 'The default: the "$receivedAlbum" album' : 'The default'),
            trailing: current == fallback ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, 'default'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'pick') {
      final picked = await FilePicker.getDirectoryPath(dialogTitle: 'Choose a folder');
      if (picked == null) return;
      final (:folder, :problem) = phoneFolder(picked, roots);
      if (folder == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem!)));
        return;
      }
      if (media) {
        await _receiver.setMediaFolder(folder);
      } else {
        await _receiver.setFilesFolder(folder);
      }
    } else {
      if (media) {
        await _receiver.setMediaFolder(null);
      } else {
        await _receiver.setFilesFolder(null);
      }
    }
    if (!mounted) return;
    setState(() {});
    final now = media ? _receiver.mediaFolder : _receiver.filesFolder;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(media
          ? 'Received photos and videos will go to $now (the "${_receiver.album}" album)'
          : 'Received files will go to $now'),
    ));
  }

  /// What scanning has learned about this phone's chips so far.
  AccelState? _chips;

  /// What's known about the graphics chip finding faces next to ML Kit.
  AccelState? _finder;

  Future<void> _loadChips() async {
    final chips = await c.faceChips();
    final finder = await c.gpuFinder();
    if (mounted) {
      setState(() {
        _chips = chips;
        _finder = finder;
      });
    }
  }

  /// "Graphics chip also finds faces · 18 ms a photo", or why not.
  String? get _finderNote {
    final f = _finder;
    if (f == null || c.faceChip == AccelChoice.cpu) return null;
    if (f.bad.contains(Accel.gpu)) return "Graphics chip can't find faces on this phone";
    final ms = f.ms[Accel.gpu];
    if (ms == null) return 'Graphics chip also finds faces · tried on the next scan';
    return 'Graphics chip also finds faces · ${ms.round()} ms a photo';
  }

  /// "12 ms a face", "didn't work on this phone", or nothing yet.
  String? _chipNote(Accel chip) {
    final chips = _chips;
    if (chips == null) return null;
    if (chips.bad.contains(chip)) return "didn't work on this phone";
    if (chips.unfinished(chip)) return 'last try was cut short · tries again on the next scan';
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
    final picked = await showModalBottomSheet<Object>(
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
          const Divider(indent: 16, endIndent: 16),
          ListTile(
            leading: const Icon(Icons.refresh_rounded),
            title: const Text('Test the chips again'),
            subtitle: const Text('The next scan tries the GPU and NPU afresh'),
            onTap: () => Navigator.pop(context, 'retest'),
          ),
        ]),
      ),
    );
    if (picked == 'retest') {
      await c.retestChips();
      await _loadChips();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The GPU and NPU will be tried again on the next scan.')),
      );
      return;
    }
    if (picked is! AccelChoice) return;
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
    // A computer saves it where you choose; a phone shares it to an app.
    if (DesktopLayout.on) {
      final saved = await FilePicker.saveFile(
        fileName: file.uri.pathSegments.last,
        bytes: await file.readAsBytes(),
        dialogTitle: 'Save the backup',
      );
      if (saved == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup saved. It contains face data, so keep it private.')),
      );
      return;
    }
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

    final desk = DesktopLayout.on;
    final windows = defaultTargetPlatform == TargetPlatform.windows;

    final profile = ListenableBuilder(
      listenable: c,
      builder: (context, _) => SectionCard(
        child: SectionRow(
          leading: CircleAvatar(
            radius: 20,
            backgroundColor: scheme.surfaceContainerHighest,
            backgroundImage: c.profile.thumb == null ? null : FaceImage(c.profile.thumb!),
            child: c.profile.thumb == null ? Icon(Icons.face_rounded, color: scheme.onSurfaceVariant) : null,
          ),
          title: 'Profile',
          subtitle: c.profile.isSet ? 'Your face is set · ${c.sharing.identity.alias}' : 'Set up your face for trip groups',
          chevron: true,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c))),
        ),
      ),
    );

    final strictIntro = [
      Text('Grouping strictness', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        'Loose puts more faces together (may mix people up). '
        'Strict keeps groups clean (may split one person into several).',
        style: text.bodySmall?.copyWith(fontSize: TextSize.label, color: scheme.onSurfaceVariant),
      ),
    ];
    final strictSlider = [
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
    ];
    final strictPreview = AnimatedSwitcher(
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
    );
    final strictApply = AnimatedSize(
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
    );
    final strictNote = Text(
      'Named people and faces you fixed by hand are never changed.',
      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
    final grouping = SectionCard(
      padding: const EdgeInsets.all(20),
      child: desk
          // Wide: the slider on the left, the live count beside it.
          ? Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ...strictIntro,
                  const SizedBox(height: 12),
                  ...strictSlider,
                  const SizedBox(height: 12),
                  strictApply,
                  const SizedBox(height: 4),
                  strictNote,
                ]),
              ),
              const SizedBox(width: 24),
              SizedBox(width: 190, child: Center(child: strictPreview)),
            ])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...strictIntro,
                const SizedBox(height: 16),
                ...strictSlider,
                const SizedBox(height: 16),
                Center(child: strictPreview),
                const SizedBox(height: 16),
                strictApply,
                const SizedBox(height: 4),
                strictNote,
              ],
            ),
    );

    final appearance = desk
        ? [
            SectionCard(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: Appearance.mode,
                builder: (context, mode, _) => Row(children: [
                  for (final (m, label) in const [
                    (ThemeMode.system, 'Automatic'),
                    (ThemeMode.light, 'Light'),
                    (ThemeMode.dark, 'Dark'),
                  ]) ...[
                    if (m != ThemeMode.system) const SizedBox(width: 18),
                    _LookChoice(
                      mode: m,
                      label: label,
                      selected: mode == m,
                      onTap: () => Appearance.set(c.db, m),
                    ),
                  ],
                ]),
              ),
            ),
            SectionFooter('Automatic follows ${Device.macos ? 'macOS' : 'Windows'}\' light or dark mode.'),
          ]
        : [
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
      SectionFooter(desk
          ? 'System follows your computer\'s light or dark mode.'
          : 'System follows your phone\'s dark mode setting.'),
          ];

    final sharing = [
      SectionCard.rows(rows: [
        SectionRow(
          leading: const IconTile(icon: Icons.badge_rounded, color: Color(0xFF0A84FF)),
          title: desk ? 'Name on other devices' : 'Name on other phones',
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
        // Where received files are saved.
        if (desk) ...[
          SectionRow(
            leading: const IconTile(icon: Icons.folder_rounded, color: Color(0xFF30D158)),
            title: 'Save received files to',
            subtitle: _receiver.desktopShown,
            trailing: IconButton(
              tooltip: 'Open the folder',
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              onPressed: _openDesktopFolder,
            ),
            onTap: _pickDesktopFolder,
          ),
          if (_receiver.desktopFolder != null)
            SectionRow(
              leading: const IconTile(icon: Icons.restart_alt_rounded, color: Color(0xFF8E8E93)),
              title: 'Use the Downloads folder again',
              onTap: () async {
                await _receiver.setDesktopFolder(null);
                if (mounted) setState(() {});
              },
            ),
        ] else if (!Device.ios) ...[
          // Android 9 always puts received photos in Pictures.
          if (_sdk == 0 || _sdk >= 29)
            SectionRow(
              leading: const IconTile(icon: Icons.photo_library_rounded, color: Color(0xFF30D158)),
              title: 'Received photos and videos',
              subtitle: _receiver.mediaFolder,
              chevron: true,
              onTap: () => _pickPhoneFolder(media: true),
            ),
          SectionRow(
            leading: const IconTile(icon: Icons.folder_rounded, color: Color(0xFFFF9F0A)),
            title: 'Received files',
            subtitle: _receiver.filesFolder,
            chevron: true,
            onTap: () => _pickPhoneFolder(media: false),
          ),
        ],
      ]),
    ];

    final general = [
      SectionCard.rows(rows: [
        SectionRow(
          leading: const IconTile(icon: Icons.sync_rounded, color: Color(0xFF30B0C7)),
          title: 'Auto-scan new photos',
          subtitle: desk
              ? 'When a scanned folder gets new photos, scan just those'
              : 'When a scanned album gets new photos, scan just those',
          trailing: Switch(value: c.autoScanEnabled, onChanged: setAutoScan),
          onTap: () => setAutoScan(!c.autoScanEnabled),
        ),
        if (!desk)
          SectionRow(
            leading: const IconTile(icon: Icons.memory_rounded, color: Color(0xFF5E5CE6)),
            title: 'Scan with my computer',
            subtitle: c.helperPc == null
                ? 'Use your computer to scan much faster'
                : c.helperOn
                    ? 'Using ${c.helperPcName ?? 'your computer'} when it\'s nearby'
                    : 'Off · ${c.helperPcName ?? 'your computer'}',
            chevron: true,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScanHelperScreen(controller: c)))
                .then((_) => setState(() {})),
          ),
        if (desk && c.scanHelper != null) ...[
          SectionRow(
            leading: const IconTile(icon: Icons.memory_rounded, color: Color(0xFF5E5CE6)),
            title: 'Help my phone scan',
            subtitle: 'Your phone sends small copies; this computer finds the faces and sends back only the results',
            trailing: Switch(
              value: c.scanHelper!.allowed,
              onChanged: (v) async {
                await c.scanHelper!.setAllowed(v);
                setState(() {});
              },
            ),
            onTap: () async {
              await c.scanHelper!.setAllowed(!c.scanHelper!.allowed);
              setState(() {});
            },
          ),
          if (c.scanHelper!.allowed)
            SectionRow(
              leading: const IconTile(icon: Icons.insights_rounded, color: Color(0xFF34C759)),
              title: 'Scanning for phones',
              subtitle: c.scanHelper!.active.isEmpty
                  ? 'Speed, photos left and other details while a phone scans with this computer'
                  : 'Now: ${c.scanHelper!.active.map((s) => s.alias).join(', ')}',
              chevron: true,
              onTap: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ScanHelperDashboard(controller: c))),
            ),
          if (c.scanHelper!.pairedCount > 0)
            SectionRow(
              leading: const IconTile(icon: Icons.phonelink_erase_rounded, color: Color(0xFF8E8E93)),
              title: 'Forget allowed phones',
              subtitle: '${c.scanHelper!.pairedCount} ${c.scanHelper!.pairedCount == 1 ? 'phone' : 'phones'} can use '
                  'this computer without asking',
              onTap: () async {
                await c.scanHelper!.forgetAll();
                setState(() {});
              },
            ),
        ],
        // Phones only: desktop scanning doesn't use the phone's chips.
        if (!desk)
          SectionRow(
            leading: const IconTile(icon: Icons.memory_rounded, color: Color(0xFFFF375F)),
            title: 'Face scanning chip',
            subtitle: [_chipSummary, ?_finderNote].join('\n'),
            chevron: true,
            onTap: _pickChip,
          ),
        SectionRow(
          leading: const IconTile(icon: Icons.lock_rounded, color: Color(0xFF8E8E93)),
          title: 'App lock',
          subtitle: !desk
              ? 'Fingerprint, face or screen lock to open the app'
              : windows
                  ? 'Windows Hello (face, fingerprint or PIN) to open the app'
                  : Device.macos
                      ? 'Touch ID or your Mac\'s password to open the app'
                      : 'Your computer\'s sign-in to open the app',
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
    ];

    final data = [
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
    ];

    final updates = [
      if (desk) ...[
        const SoftwareUpdatePanel(),
        const SizedBox(height: 20),
      ],
      ListenableBuilder(
        listenable: Updater.instance,
        builder: (context, _) {
          final u = Updater.instance;
          return SectionCard.rows(rows: [
            SectionRow(
              leading: const IconTile(icon: Icons.update_rounded, color: Color(0xFF34C759)),
              title: 'Check for updates automatically',
              subtitle: desk
                  ? "Once a day. A dot on your profile in the sidebar shows when there's a new version"
                  : "Once a day, and tells you when there's a new version",
              trailing: Switch(value: u.autoCheck, onChanged: u.setAutoCheck),
              onTap: () => u.setAutoCheck(!u.autoCheck),
            ),
            if (!desk)
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
    ];

    final sections = [
      _Section('profile', 'Profile', Icons.account_circle_rounded, [desk ? _deskProfile(context) : profile],
          header: false,
          color: const Color(0xFF8E8E93),
          note: 'Your face, for trip groups, and the name others see',
          keywords: const ['face', 'name', 'selfie', 'me', 'you']),
      _Section('grouping', 'Face grouping', Icons.face_retouching_natural_rounded, [grouping],
          header: false,
          color: const Color(0xFF5E5CE6),
          note: 'How strictly faces are put together into people',
          keywords: const ['strict', 'loose', 'merge', 'regroup', 'people', 'faces']),
      _Section('appearance', 'Appearance', Icons.contrast_rounded, appearance,
          color: const Color(0xFF3A3A3C),
          note: 'Light, dark, or the same as ${desk ? (Device.macos ? 'macOS' : 'Windows') : 'your phone'}',
          keywords: const ['dark', 'light', 'theme', 'mode', 'colour', 'color']),
      _Section('sharing', 'Sharing', Icons.swap_horiz_rounded, sharing,
          color: const Color(0xFF0A84FF),
          note: 'How you show up on other devices, what you send, and where received files go',
          keywords: const [
            'send', 'device', 'name', 'quality', 'location', 'gps', 'original', //
            'receive', 'received', 'folder', 'directory', 'save', 'download', 'location',
          ]),
      _Section('general', 'General', Icons.settings_rounded, general,
          color: const Color(0xFF8E8E93),
          note: 'Scanning, app lock and the island',
          keywords: const ['scan', 'auto', 'lock', 'windows hello', 'password', 'island', 'notification']),
      _Section('data', 'Your data', Icons.storage_rounded, data,
          color: const Color(0xFF34C759),
          note: 'Storage, backups, and clearing what ShareBro knows',
          keywords: const ['storage', 'backup', 'restore', 'clear', 'delete', 'hidden', 'not in our group', 'space']),
      if (Device.selfUpdate)
        _Section('updates', desk ? 'Software update' : 'Updates', Icons.system_update_alt_rounded, updates,
            color: Brand.accentLight,
            note: 'Get new versions of ShareBro',
            keywords: const ['update', 'version', 'download', 'new', 'upgrade']),
      const _Section('about', 'About', Icons.info_rounded, [_AboutCard()],
          color: Color(0xFF30B0C7),
          note: 'Who made ShareBro',
          keywords: ['about', 'developer', 'source', 'code', 'github', 'licence', 'license']),
    ];

    if (desk) return _desktop(context, sections);

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
                for (final (i, s) in sections.indexed) ...[
                  if (s.header)
                    SectionHeader(title: s.title)
                  else if (i > 0)
                    const SizedBox(height: 16),
                  ...s.children,
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Desktop: the list of sections on the left, one section beside it,
  // like a Mac's System Settings ----

  late String _pane = widget.section ?? 'profile';

  void _show(String id) {
    if (id != _pane) setState(() => _pane = id);
  }

  /// Desktop Profile: a large picture, the name others see, whether the
  /// face is set, and buttons to change either.
  Widget _deskProfile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final thumb = c.profile.thumb;
        void edit() => Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(controller: c)));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionCard(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.profile.isSet ? scheme.primary : Mac.hairline(context),
                ),
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: scheme.surfaceContainerHighest,
                  backgroundImage: thumb == null ? null : FaceImage(thumb),
                  child: thumb == null ? Icon(Icons.face_rounded, size: 32, color: scheme.onSurfaceVariant) : null,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.sharing.identity.alias, style: text.titleLarge),
                  const SizedBox(height: 3),
                  Row(children: [
                    Icon(c.profile.isSet ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                        size: 15, color: c.profile.isSet ? Mac.green : scheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        c.profile.isSet ? 'Your face is set up' : 'Your face isn\'t set up yet',
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  ]),
                ]),
              ),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _renameDevice, child: const Text('Change name')),
              const SizedBox(width: 8),
              FilledButton(onPressed: edit, child: Text(c.profile.isSet ? 'Edit profile' : 'Set up face')),
            ]),
          ),
          const SectionFooter(
            'Your face lets trip groups find the photos you\'re in; your name is what other devices see when you '
            'send or receive. Both stay on this computer.',
          ),
        ]);
      },
    );
  }

  Widget _desktop(BuildContext context, List<_Section> sections) {
    final index = sections.indexWhere((s) => s.id == _pane);
    final section = sections[index < 0 ? 0 : index];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: LayoutBuilder(builder: (context, box) {
        final list = box.maxWidth >= 640;
        // The pane: a header with the section's icon, name and what's in
        // it, then its settings.
        final pane = Scrollbar(
          key: ValueKey(section.id),
          child: ListView(padding: const EdgeInsets.fromLTRB(28, 26, 28, 48), children: [
            Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    if (Navigator.of(context).canPop()) ...[
                      GlassIconButton(
                        tooltip: 'Back (Esc)',
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (!list) ...[
                      PopupMenuButton<String>(
                        tooltip: 'All settings',
                        icon: const Icon(Icons.menu_rounded),
                        onSelected: _show,
                        itemBuilder: (_) => [
                          for (final s in sections)
                            menuChoice(context, s.id, s.title, selected: s.id == section.id, icon: s.icon),
                        ],
                      ),
                      const SizedBox(width: 6),
                    ],
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: section.color, borderRadius: BorderRadius.circular(11)),
                      child: Icon(section.icon, size: 26, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(section.title, style: text.headlineSmall),
                        if (section.note != null)
                          Text(section.note!, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 22),
                  ...section.children,
                ]),
              ),
            ),
          ]),
        );
        final animated = AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
          child: pane,
        );
        if (!list) return animated;
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            width: 236,
            decoration: BoxDecoration(
              color: Mac.sidebar(context).withValues(alpha: 0.5),
              border: Border(right: BorderSide(color: Mac.hairline(context), width: 0.5)),
            ),
            child: _SettingsNav(
              controller: c,
              sections: sections,
              selected: section.id,
              onSelect: _show,
            ),
          ),
          Expanded(child: animated),
        ]);
      }),
    );
  }
}

/// One part of Settings: its title, icon and colour (for the desktop list),
/// a line about what's in it, and words that find it in the search.
class _Section {
  const _Section(this.id, this.title, this.icon, this.children,
      {this.header = true, this.color = const Color(0xFF8E8E93), this.note, this.keywords = const []});

  final String id;
  final String title;
  final IconData icon;
  final Color color;
  final String? note;
  final List<String> keywords;
  final List<Widget> children;

  /// Phones show a header above it; Profile and grouping go without one.
  final bool header;

  bool matches(String q) =>
      title.toLowerCase().contains(q) ||
      (note?.toLowerCase().contains(q) ?? false) ||
      keywords.any((k) => k.contains(q));
}

/// A small coloured tile with a white symbol, as in a Mac's settings list.
class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Icon(icon, size: 14, color: Colors.white),
      );
}

/// Desktop: the list beside the pane, like a Mac's System Settings: a
/// search box, you, then the sections in small groups, the version at the
/// foot. Typing filters the list; Enter opens the first match.
class _SettingsNav extends StatefulWidget {
  const _SettingsNav({
    required this.controller,
    required this.sections,
    required this.selected,
    required this.onSelect,
  });

  final ScanController controller;
  final List<_Section> sections;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  State<_SettingsNav> createState() => _SettingsNavState();
}

class _SettingsNavState extends State<_SettingsNav> {
  final _search = TextEditingController();
  String _q = '';

  /// Which sections go together (a gap between groups).
  static const _groups = [
    ['grouping', 'appearance'],
    ['sharing', 'general'],
    ['data', 'updates'],
    ['about'],
  ];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.controller;
    final faint = Mac.secondary(context);
    final q = _q.trim().toLowerCase();
    final found = q.isEmpty ? null : [for (final s in widget.sections) if (s.matches(q)) s];

    Widget row({required String id, required Widget leading, required Widget label, Widget? trailing, double height = 32}) {
      final on = id == widget.selected;
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: on ? Mac.selection(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(Mac.rowRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(Mac.rowRadius),
            mouseCursor: SystemMouseCursors.click,
            onTap: () => widget.onSelect(id),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [leading, const SizedBox(width: 10), Expanded(child: label), ?trailing]),
              ),
            ),
          ),
        ),
      );
    }

    Widget sectionRow(_Section s) => row(
          id: s.id,
          leading: _NavTile(icon: s.icon, color: s.color),
          label: Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: TextSize.caption,
              fontWeight: s.id == widget.selected ? FontWeight.w600 : FontWeight.w400,
              color: scheme.onSurface,
            ),
          ),
          trailing: s.id == 'updates'
              ? ListenableBuilder(
                  listenable: Updater.instance,
                  builder: (context, _) => Updater.instance.hasUpdate
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(99)),
                          child: Text('1',
                              style: TextStyle(fontSize: TextSize.tiny, fontWeight: FontWeight.w700, color: scheme.onPrimary)),
                        )
                      : const SizedBox.shrink(),
                )
              : null,
        );

    final byId = {for (final s in widget.sections) s.id: s};
    final profile = byId['profile'];
    final children = <Widget>[
      SizedBox(
        height: 30,
        child: TextField(
          controller: _search,
          onChanged: (v) => setState(() => _q = v),
          onSubmitted: (_) {
            final first = found?.firstOrNull;
            if (first != null) widget.onSelect(first.id);
          },
          style: const TextStyle(fontSize: TextSize.caption),
          decoration: InputDecoration(
            hintText: 'Search settings',
            hintStyle: TextStyle(fontSize: TextSize.caption, color: faint),
            prefixIcon: Icon(Icons.search_rounded, size: 16, color: faint),
            prefixIconConstraints: const BoxConstraints(minWidth: 30),
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    iconSize: 14,
                    style: IconButton.styleFrom(minimumSize: const Size(24, 24), padding: EdgeInsets.zero),
                    onPressed: () => setState(() {
                      _search.clear();
                      _q = '';
                    }),
                    icon: const Icon(Icons.cancel_rounded),
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            filled: true,
            fillColor: scheme.onSurface.withValues(alpha: 0.06),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(Mac.controlRadius), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Mac.controlRadius), borderSide: BorderSide.none),
          ),
        ),
      ),
      const SizedBox(height: 12),
    ];
    if (found != null) {
      children.addAll(found.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text('No settings match "${_q.trim()}"', style: TextStyle(fontSize: TextSize.small, color: faint)),
              ),
            ]
          : [for (final s in found) sectionRow(s)]);
    } else {
      if (profile != null) {
        children.add(ListenableBuilder(
          listenable: c,
          builder: (context, _) => row(
            id: profile.id,
            height: 52,
            leading: CircleAvatar(
              radius: 17,
              backgroundColor: scheme.surfaceContainerHighest,
              backgroundImage: c.profile.thumb == null ? null : FaceImage(c.profile.thumb!),
              child: c.profile.thumb == null ? Icon(Icons.face_rounded, size: 18, color: faint) : null,
            ),
            label: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.sharing.identity.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
              Text(c.profile.isSet ? 'Profile · face set' : 'Set up your profile',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: TextSize.tiny, color: faint)),
            ]),
          ),
        ));
      }
      final placed = <String>{'profile'};
      for (final group in _groups) {
        final rows = [for (final id in group) ?byId[id]];
        if (rows.isEmpty) continue;
        children.add(const SizedBox(height: 12));
        for (final s in rows) {
          children.add(sectionRow(s));
          placed.add(s.id);
        }
      }
      // Anything not in a group still shows.
      for (final s in widget.sections) {
        if (!placed.contains(s.id)) children.add(sectionRow(s));
      }
    }
    children.addAll([
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text('ShareBro ${Updater.instance.currentText}', style: TextStyle(fontSize: TextSize.tiny, color: faint)),
      ),
    ]);
    return ListView(padding: const EdgeInsets.fromLTRB(10, 16, 10, 16), children: children);
  }
}

/// Settings › Appearance on a computer: a small picture of the window in
/// each look, like a Mac's appearance choice.
class _LookChoice extends StatefulWidget {
  const _LookChoice({required this.mode, required this.label, required this.selected, required this.onTap});

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_LookChoice> createState() => _LookChoiceState();
}

class _LookChoiceState extends State<_LookChoice> {
  bool _hover = false;

  /// A tiny window: a sidebar, a title line and three cards.
  static Widget _window(bool dark) {
    final bg = dark ? Mac.windowDark : Mac.windowLight;
    final side = dark ? Mac.sidebarDark : Mac.sidebarLight;
    final card = dark ? Mac.cardDark : Mac.cardLight;
    final line = dark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6);
    return ColoredBox(
      color: bg,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 30,
          color: side,
          padding: const EdgeInsets.fromLTRB(5, 8, 5, 0),
          child: Column(children: [
            for (var i = 0; i < 4; i++)
              Container(
                height: 4,
                margin: const EdgeInsets.only(bottom: 5),
                decoration: BoxDecoration(
                  color: i == 0 ? Brand.accentLight.withValues(alpha: 0.8) : line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 8, 7, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 34, height: 5, decoration: BoxDecoration(color: line, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 7),
              Row(children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 22,
                      decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final picture = switch (widget.mode) {
      ThemeMode.light => _window(false),
      ThemeMode.dark => _window(true),
      // Automatic: light on the left, dark on the right.
      ThemeMode.system => Stack(fit: StackFit.expand, children: [
          _window(false),
          ClipPath(clipper: _RightHalf(), child: _window(true)),
        ]),
    };
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.label} appearance',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 112,
              height: 72,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.selected
                      ? scheme.primary
                      : _hover
                          ? scheme.onSurface.withValues(alpha: 0.25)
                          : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Mac.hairline(context), width: 0.5),
                ),
                child: picture,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: TextSize.caption,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                color: widget.selected ? scheme.onSurface : Mac.secondary(context),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _RightHalf extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width * 0.55, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width * 0.45, size.height)
    ..close();

  @override
  bool shouldReclip(_RightHalf old) => false;
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
        // A computer has a Software update section of its own.
        if (Device.selfUpdate && !DesktopLayout.on) ...[
          const _UpdateRow(),
          const Divider(height: 0.5, thickness: 0.5, indent: 62),
        ],
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
        style: TextStyle(color: Colors.white, fontSize: TextSize.small, fontWeight: FontWeight.w800, letterSpacing: 0.4),
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
                          : FaceImage(p.coverThumb!),
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
