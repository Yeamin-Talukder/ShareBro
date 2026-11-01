import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:share_plus/share_plus.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'explore_screen.dart';
import 'glass.dart';
import 'motion.dart';
import 'photo_viewer.dart';
import 'reel_screen.dart';
import 'sections.dart';
import 'send_sheet.dart';
import 'together_screen.dart';
import 'widgets.dart';

/// Messaging apps cap how many files one share can carry, so big sets go out
/// in batches.
const _shareBatch = 100;

/// Faces sharper than this count as "not blurry" (see `_sharpness`).
const _blurLimit = 60.0;

enum PhotoKind { all, solo, group }

/// "Best 20" size, and what counts as smiling / eyes open for the filters.
const _bestCount = 20;
const _smileLimit = 0.6;
const _eyesLimit = 0.4;

extension on PersonPhoto {
  /// Alone in the photo, or their face fills a good part of it.
  bool get isSolo => faceCount == 1 || face.width >= 0.25;
  bool get isGroup => faceCount >= 3;
  bool get isBlurry => sharpness != null && sharpness! < _blurLimit;
}

class PersonScreen extends StatefulWidget {
  const PersonScreen({
    super.key,
    required this.controller,
    required this.personId,
    this.tripId,
    this.dates,
  });

  final ScanController controller;
  final int personId;

  /// Trip selected on the home screen; null = all trips.
  final int? tripId;

  /// Date range selected on the home screen; null = any date.
  final DaySpan? dates;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  ScanController get c => widget.controller;
  PersonSummary? _person;
  List<PersonPhoto> _all = const [];
  List<FaceThumb> _faces = const [];
  final Set<String> _selected = {};

  /// "Choose photos" mode: tap photos to pick exactly which ones to send.
  bool _choosing = false;

  void _startChoosing() {
    Haptics.lift();
    setState(() {
      _choosing = true;
      // Start with everything picked; tapping removes the ones you don't want.
      _selected
        ..clear()
        ..addAll(_visible.map((p) => p.assetId));
    });
  }

  void _stopChoosing() => setState(() {
        _choosing = false;
        _selected.clear();
      });

  /// The chosen photos aren't of this person (someone else was matched by
  /// mistake): take this person off them. Their faces go to Unmatched, to
  /// move to whoever they really are.
  Future<void> _notThem() async {
    final person = _person;
    final ids = [for (final p in _visible) if (_selected.contains(p.assetId)) p.assetId];
    if (person == null || ids.isEmpty) return;
    final name = person.displayName;
    final what = ids.length == 1 ? 'this photo' : '${ids.length} photos';
    // Choose starts with everything picked: make sure a big batch is meant.
    if (ids.length > 3) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove $name from $what?'),
          content: const Text('The faces in them go to Unmatched, where you can move them to the right person.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
          ],
        ),
      );
      if (ok != true) return;
    }
    Haptics.remove();
    final undo = await c.db.removePersonFrom(person.id, ids);
    if (!mounted) return;
    setState(() {
      _all = [for (final p in _all) if (!ids.contains(p.assetId)) p];
      _choosing = false;
      _selected.clear();
    });
    c.changed();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed $name from $what'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await c.db.restore(undo);
            c.changed();
            await _load();
          },
        ),
      ));
    await _load();
  }

  /// Called whenever the grid or viewer changes the selection.
  void _selectionChanged() => setState(() {
        if (_selected.isNotEmpty) _choosing = true;
      });
  late int? _tripId = widget.tripId;
  late DaySpan? _dates = widget.dates;
  String? _tripName;
  ColorScheme? _scheme;

  PhotoKind _kind = PhotoKind.all;

  /// Tags of each of this person's photos, and the chosen category (if any).
  Map<String, Set<String>> _tags = const {};
  String? _category;
  bool _bestFirst = false;
  bool _hideBlurry = false;

  /// Only this person's top shots, smiling ones, or ones with eyes open.
  bool _best20 = false;
  bool _smiling = false;
  bool _eyesOpen = false;

  /// Bumped after renaming so the header name types itself in.
  int _revealName = 0;

  final _avatarKey = GlobalKey();
  int _splits = 0;

  /// Faces currently flying out of the grid.
  final Set<int> _leaving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final person = await c.db.person(widget.personId);
    if (person == null) {
      // Every face was removed or merged away.
      if (mounted) Navigator.pop(context);
      return;
    }
    final photos = await c.db.photosOf(widget.personId, tripId: _tripId, dates: _dates);
    _ignored = await c.db.isIgnored(widget.personId);
    _sentCount = (await c.db.sentTo(widget.personId)).length;
    final faces = await c.db.facesOf(widget.personId);
    final tags = await c.db.tagsFor(photos.map((p) => p.assetId));
    String? tripName;
    if (_tripId != null) {
      for (final t in await c.db.trips()) {
        if (t.id == _tripId) tripName = t.name;
      }
    }
    if (!mounted) return;
    setState(() {
      _person = person;
      _all = photos;
      _faces = faces;
      _tags = tags;
      _tripName = tripName;
      _selected.retainAll(photos.map((p) => p.assetId));
    });
    if (_scheme == null && person.coverThumb != null) _themeFrom(person);
  }

  /// Tints the page with colours from the person's own face photo.
  Future<void> _themeFrom(PersonSummary person) async {
    final brightness = Theme.of(context).brightness;
    final scheme = await ColorScheme.fromImageProvider(
        provider: MemoryImage(person.coverThumb!), brightness: brightness);
    if (mounted) setState(() => _scheme = scheme);
  }

  List<PersonPhoto> get _visible {
    final list = [
      for (final p in _all)
        if ((_kind == PhotoKind.all ||
                (_kind == PhotoKind.solo && p.isSolo) ||
                (_kind == PhotoKind.group && p.isGroup)) &&
            !(_hideBlurry && p.isBlurry) &&
            (_category == null ||
                (_tags[p.assetId]?.contains(_category) ?? false)))
          p,
    ];
    list.removeWhere((p) =>
        (_smiling && (p.smile ?? 0) < _smileLimit) ||
        (_eyesOpen && (p.eyesOpen ?? 1) < _eyesLimit));
    if (_bestFirst || _best20) list.sort((a, b) => b.quality.compareTo(a.quality));
    if (_best20) {
      // Leave out blinks and blurry shots before picking the top 20.
      final good = list.where((p) => (p.eyesOpen ?? 1) >= _eyesLimit && !p.isBlurry).toList();
      return (good.length >= _bestCount ? good : list).take(_bestCount).toList();
    }
    return list;
  }

  Future<void> _rename() async {
    final text = TextEditingController(text: _person?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Who is this?'),
        content: TextField(
          controller: text,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, text.text),
              child: const Text('Save')),
        ],
      ),
    );
    text.dispose();
    if (name == null) return;
    final id = await c.db.renamePerson(widget.personId, name);
    c.changed();
    if (!mounted) return;
    if (id != widget.personId) {
      // The name already existed, so the two were merged.
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Merged with the existing ${AppDb.cleanName(name)}')));
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) =>
                PersonScreen(
                    controller: c, personId: id, tripId: _tripId, dates: _dates)),
      );
      return;
    }
    Haptics.success();
    // Play the type-in reveal for the new name.
    _revealName++;
    await _load();
  }

  /// "Not in our group" hides a stranger everywhere.
  bool _ignored = false;

  /// How many of this person's photos have been sent to them.
  int _sentCount = 0;

  Future<void> _menu(String action) async {
    final person = _person;
    if (person == null) return;
    switch (action) {
      case 'nickname':
        final text = TextEditingController(text: person.nickname ?? '');
        final nick = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Nickname'),
            content: TextField(
              controller: text,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'What friends call them'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, text.text),
                  child: const Text('Save')),
            ],
          ),
        );
        if (nick == null) return;
        await c.db.setNickname(person.id, nick);
        Haptics.success();
      case 'gender':
        final picked = await showDialog<(Gender?,)>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text('${person.displayName} is'),
            children: [
              for (final g in Gender.values)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, (g,)),
                  child: Row(children: [
                    Icon(g == Gender.male ? Icons.male_rounded : Icons.female_rounded),
                    const SizedBox(width: 12),
                    Expanded(child: Text(g.label)),
                    if (person.gender == g && !person.genderGuessed) const Icon(Icons.check_rounded),
                  ]),
                ),
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, (null,)),
                child: Row(children: [
                  const Icon(Icons.auto_awesome_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(person.genderGuessed && person.gender != null
                        ? 'Let ShareBro guess (now ${person.gender!.label.toLowerCase()})'
                        : 'Let ShareBro guess'),
                  ),
                  if (person.genderGuessed || person.gender == null) const Icon(Icons.check_rounded),
                ]),
              ),
            ],
          ),
        );
        if (picked == null) return;
        await c.db.setGender(person.id, picked.$1);
        Haptics.success();
      case 'together':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TogetherScreen(
                controller: c, tripId: _tripId, initial: {person.id}),
          ),
        );
        return;
      case 'ignore':
        final ignore = !_ignored;
        await c.db.setIgnored(person.id, ignore);
        Haptics.remove();
        c.changed();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ignore
              ? '${person.displayName} is hidden from People and Review'
              : '${person.displayName} is back in People'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              await c.db.setIgnored(person.id, !ignore);
              c.changed();
            },
          ),
        ));
    }
    c.changed();
    await _load();
  }

  Future<void> _useAsCover(FaceThumb face) async {
    Haptics.success();
    await c.db.setCover(widget.personId, face.id);
    c.changed();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Cover photo updated')));
  }

  void _playReel() {
    final person = _person;
    if (person == null || _all.isEmpty) return;
    Haptics.lift();
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        transitionDuration: 350.ms,
        reverseTransitionDuration: 300.ms,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: ReelScreen(person: person, photos: _all),
        ),
      ),
    );
  }

  /// A little copy of the removed face splits off the header circle and
  /// floats away.
  void _splitOff(Uint8List thumb) {
    final box = _avatarKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: centre.dx - 18,
        top: centre.dy - 18,
        child: IgnorePointer(
          child: CircleAvatar(radius: 18, backgroundImage: MemoryImage(thumb))
              .animate(onComplete: (_) => entry.remove())
              .scaleXY(begin: 0.3, end: 1, duration: 250.ms, curve: Curves.easeOutBack)
              .move(
                  end: Offset(_splits.isEven ? 90 : -90, -40),
                  duration: 800.ms,
                  curve: Curves.easeOutCubic)
              .rotate(end: _splits.isEven ? 0.3 : -0.3, duration: 800.ms)
              .fadeOut(delay: 450.ms, duration: 350.ms),
        ),
      ),
    );
    _splits++;
    Overlay.of(context).insert(entry);
  }

  Future<void> _rejectFace(FaceThumb face) async {
    Haptics.remove();
    _splitOff(face.thumb);
    setState(() => _leaving.add(face.id));
    final undo = await c.db.rejectFace(face.id);
    await Future<void>.delayed(400.ms);
    if (!mounted) return;
    setState(() {
      _leaving.remove(face.id);
      _faces = [for (final f in _faces) if (f.id != face.id) f];
    });
    c.changed();
    _undoBatch.add(undo);
    _removedCount.value = _undoBatch.length;
    // One message for a run of removals that counts up, instead of a new
    // one sliding in for every face; Undo brings back the whole run.
    if (_undoBar == null) {
      final bar = _undoBar = ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: ValueListenableBuilder<int>(
          valueListenable: _removedCount,
          builder: (_, n, _) => Text(n == 1 ? 'Face removed' : '$n faces removed'),
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            final run = List.of(_undoBatch);
            _undoBatch.clear();
            for (final u in run.reversed) {
              await c.db.restore(u);
            }
            c.changed();
            await _load();
          },
        ),
      ));
      unawaited(bar.closed.then((_) {
        _undoBar = null;
        _undoBatch.clear();
      }));
    }
    if (_faces.isEmpty) await _load();
  }

  /// Face removals since the "removed" message came up, for its Undo.
  final List<FaceSnapshot> _undoBatch = [];
  final _removedCount = ValueNotifier<int>(0);
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoBar;

  @override
  void dispose() {
    _removedCount.dispose();
    super.dispose();
  }

  /// The photos a send covers: the chosen ones, or everything shown.
  List<String> get _sendIds {
    final visible = _visible;
    return _choosing
        ? [for (final p in visible) if (_selected.contains(p.assetId)) p.assetId]
        : [for (final p in visible) p.assetId];
  }

  /// Nearby phones (LocalSend), a QR code for any browser, or other apps.
  Future<void> _send() async {
    final person = _person;
    if (person == null) return;
    await showSendSheet(
      context,
      controller: c,
      personId: widget.personId,
      personName: person.displayName,
      assetIds: _sendIds,
      shareWithApps: _shareWithApps,
    );
    _sentCount = (await c.db.sentTo(widget.personId)).length;
    if (mounted) setState(() {});
  }

  /// Android's share sheet (Quick Share, WhatsApp, Bluetooth…), in batches.
  Future<void> _shareWithApps(List<String> ids) async {
    if (ids.length <= _shareBatch) {
      await _shareIds(ids);
      return;
    }
    final batches = [
      for (var i = 0; i < ids.length; i += _shareBatch)
        ids.sublist(i, (i + _shareBatch).clamp(0, ids.length)),
    ];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('${ids.length} photos — sending in batches of $_shareBatch'),
          ),
          for (var b = 0; b < batches.length; b++)
            ListTile(
              leading: const Icon(Icons.send),
              title: Text(
                  'Photos ${b * _shareBatch + 1}–${b * _shareBatch + batches[b].length}'),
              onTap: () => _shareIds(batches[b]),
            ),
        ],
      ),
    );
  }

  Future<void> _shareIds(List<String> ids) async {
    final files = <XFile>[];
    var missing = 0;
    for (final id in ids) {
      final file = await (await AssetThumb.entity(id))?.file;
      if (file == null) {
        missing++;
      } else {
        files.add(XFile(file.path));
      }
    }
    if (!mounted) return;
    if (missing > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$missing photos were deleted or moved and skipped.')));
    }
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  void _openViewer(List<PersonPhoto> photos, int index) {
    Navigator.push(
      context,
      PageRouteBuilder(
        opaque: false,
        transitionDuration: 300.ms,
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: PhotoViewer(
            ids: [for (final p in photos) p.assetId],
            initial: index,
            controller: c,
            faces: {for (final p in photos) p.assetId: p.face},
            // Pick or unpick photos while looking at them full screen.
            selection: _selected,
            onSelectionChanged: _selectionChanged,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final person = _person;
    if (person == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Column(children: [
          SizedBox(height: 12),
          Skeleton(width: 104, height: 104, circle: true),
          SizedBox(height: 14),
          Skeleton(width: 160, height: 22, radius: 8),
          SizedBox(height: 24),
          Expanded(child: PhotosSkeleton(columns: 3)),
        ]),
      );
    }
    final base = Theme.of(context);
    final scheme = _scheme ?? base.colorScheme;
    final visible = _visible;
    final selecting = _choosing;
    final sendCount = selecting
        ? visible.where((p) => _selected.contains(p.assetId)).length
        : visible.length;
    final allPicked = sendCount == visible.length;

    // Plain Theme, not AnimatedTheme: re-theming the whole page every frame
    // while it slides in made opening a person stutter.
    return Theme(
      data: base.copyWith(colorScheme: scheme),
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverAppBar(
                pinned: true,
                expandedHeight: 250,
                backgroundColor: scheme.surface,
                leadingWidth: 64,
                leading: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Center(
                    child: GlassIconButton(
                      tooltip: 'Back',
                      size: 44,
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                  ),
                ),
                actions: [
                  if (selecting)
                    TextButton(
                      onPressed: () => setState(() => allPicked
                          ? _selected.clear()
                          : _selected.addAll(visible.map((p) => p.assetId))),
                      child: Text(allPicked ? 'Select none' : 'Select all'),
                    ),
                  PopupMenuButton<String>(
                    onSelected: _menu,
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'nickname', child: Text('Set nickname')),
                      const PopupMenuItem(value: 'together', child: Text('Photos with someone…')),
                      const PopupMenuItem(value: 'gender', child: Text('Male or female…')),
                      PopupMenuItem(
                        value: 'ignore',
                        child: Text(_ignored ? 'Bring back to People' : 'Not in our group'),
                      ),
                    ],
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: DecoratedBox(
                    decoration: BoxDecoration(color: scheme.surface),
                    child: SafeArea(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 8),
                          // Tap the face to play their best photos as a reel.
                          GestureDetector(
                            onTap: _playReel,
                            child: Stack(key: _avatarKey, clipBehavior: Clip.none, children: [
                              // A solid ring in the accent, as on People.
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary),
                                child: FaceAvatar(
                                    personId: person.id,
                                    thumb: person.coverThumb,
                                    radius: 52),
                              ),
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: CircleAvatar(
                                  radius: 16,
                                  backgroundColor: scheme.primary,
                                  child: Icon(Icons.play_arrow_rounded,
                                      size: 22, color: scheme.onPrimary),
                                )
                                    .animate(onPlay: (c) => c.repeat(reverse: true))
                                    .scaleXY(end: 1.12, duration: 900.ms),
                              ),
                            ]),
                          ),
                          const SizedBox(height: 10),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: _rename,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                if (_revealName > 0)
                                  TypewriterText(
                                    person.displayName,
                                    key: ValueKey(_revealName),
                                    style: base.textTheme.headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  )
                                else
                                  Text(person.displayName,
                                      style: base.textTheme.headlineSmall
                                          ?.copyWith(fontWeight: FontWeight.w700)),
                                const SizedBox(width: 6),
                                const Icon(Icons.edit, size: 18),
                              ]),
                            ),
                          ).animate().fadeIn(delay: 150.ms).moveY(begin: 8),
                          Text(
                            '${person.nickname == null ? '' : '"${person.nickname}" · '}'
                            '${_all.length} photos'
                            '${_sentCount == 0 ? '' : ' · $_sentCount sent ✓'}'
                            '${_tripName == null ? '' : ' · $_tripName'}'
                            '${_dates == null ? '' : ' · ${formatSpan(_dates!)}'}',
                            style: base.textTheme.bodyMedium,
                          ).animate().fadeIn(delay: 250.ms),
                        ],
                      ),
                    ),
                  ),
                ),
                bottom: TabBar(tabs: [
                  Tab(text: 'Photos (${visible.length})'),
                  Tab(text: 'Faces (${_faces.length})'),
                ]),
              ),
            ],
            body: TabBarView(children: [
              Column(children: [
                _filters(),
                AnimatedSize(
                  duration: 200.ms,
                  child: selecting
                      ? Container(
                          width: double.infinity,
                          color: scheme.secondaryContainer,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: Text(
                            'Tap photos to select or deselect · $sendCount of ${visible.length} selected',
                            style: TextStyle(color: scheme.onSecondaryContainer),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                Expanded(
                  child: _PhotoGrid(
                    photos: visible,
                    selected: _selected,
                    choosing: selecting,
                    onChanged: _selectionChanged,
                    onOpen: (i) => _openViewer(visible, i),
                  ),
                ),
              ]),
              _FacesGrid(
                  faces: _faces,
                  leaving: _leaving,
                  onTap: _rejectFace,
                  onLongPress: _useAsCover),
            ]),
          ),
          extendBody: true,
          // Floating glass action bar; photos scroll underneath it.
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Glass(
                radius: 34,
                padding: const EdgeInsets.all(6),
                // A fixed height so nothing inside can stretch the bar.
                child: SizedBox(
                  height: 56,
                  child: Row(children: [
                AnimatedSwitcher(
                  duration: 200.ms,
                  child: selecting
                      ? TextButton(
                          key: const ValueKey('cancel'),
                          onPressed: _stopChoosing,
                          child: const Text('Cancel'),
                        )
                      : OutlinedButton.icon(
                          key: const ValueKey('choose'),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 56), side: BorderSide.none),
                          onPressed: visible.isEmpty ? null : _startChoosing,
                          icon: const Icon(Icons.checklist_rounded),
                          label: const Text('Choose'),
                        ),
                ),
                // Someone else's photo got in: take this person off it.
                AnimatedSwitcher(
                  duration: 200.ms,
                  transitionBuilder: (child, a) => SizeTransition(
                    sizeFactor: a,
                    axis: Axis.horizontal,
                    child: FadeTransition(opacity: a, child: child),
                  ),
                  child: selecting && _selected.isNotEmpty
                      ? Padding(
                          key: const ValueKey('not-them'),
                          padding: const EdgeInsets.only(left: 6),
                          child: IconButton.filledTonal(
                            tooltip: 'Not ${_person?.displayName ?? 'this person'}',
                            onPressed: _notThem,
                            icon: const Icon(Icons.person_remove_rounded),
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('none')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SendButton(
                    label: selecting
                        ? 'Send $sendCount selected'
                        : 'Send all $sendCount',
                    enabled: sendCount > 0,
                    onSend: _send,
                  ),
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

  /// "Category" chip listing the categories this person's photos fall in.
  Widget _categoryChip() {
    final counts = <String, int>{};
    for (final p in _all) {
      for (final t in _tags[p.assetId] ?? const <String>{}) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final options = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final chosen = _category;
    return PopupMenuButton<String?>(
      tooltip: 'Category',
      enabled: options.isNotEmpty,
      onSelected: (t) => setState(() => _category = t),
      itemBuilder: (_) => [
        const PopupMenuItem<String?>(
            value: null, child: Text('All categories')),
        for (final e in options)
          PopupMenuItem<String?>(
            value: e.key,
            child: Row(children: [
              Icon(categoryIcon(e.key), size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(categoryTitle(e.key))),
              Text('${e.value}'),
            ]),
          ),
      ],
      child: IgnorePointer(
        child: FilterChip(
          avatar: Icon(chosen == null ? Icons.category_outlined : categoryIcon(chosen),
              size: 18),
          label: Text(chosen == null ? 'Category' : categoryTitle(chosen)),
          selected: chosen != null,
          showCheckmark: false,
          onSelected: (_) {},
        ),
      ),
    );
  }

  /// How many of the extra filters are switched on (shown on the button).
  int get _activeFilters => [
        _best20,
        _smiling,
        _eyesOpen,
        _bestFirst,
        _hideBlurry,
        _category != null,
        _dates != null,
        widget.tripId != null && _tripId == null,
      ].where((on) => on).length;

  /// A clean bar: All / Solo / Group, plus one Filters button for the rest.
  Widget _filters() {
    final n = _activeFilters;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Row(children: [
        Expanded(
          child: CapsuleSwitch<PhotoKind>(
            value: _kind,
            options: const [(PhotoKind.all, 'All', null), (PhotoKind.solo, 'Solo', null), (PhotoKind.group, 'Group', null)],
            onChanged: (k) => setState(() => _kind = k),
          ),
        ),
        const SizedBox(width: 8),
        Badge(
          isLabelVisible: n > 0,
          label: Text('$n'),
          child: IconButton.filledTonal(
            tooltip: 'Filters',
            onPressed: _openFilters,
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
      ]),
    );
  }

  Future<void> _openFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        void set(VoidCallback f) {
          Haptics.tick();
          setState(f);
          setSheet(() {});
        }

        final text = Theme.of(context).textTheme;
        Widget chip(IconData icon, String label, bool on, ValueChanged<bool> onChanged) => FilterChip(
              avatar: Icon(icon, size: 18),
              label: Text(label),
              selected: on,
              onSelected: (v) => set(() => onChanged(v)),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('Filters', style: text.headlineSmall)),
                if (_activeFilters > 0)
                  TextButton(
                    onPressed: () => set(() {
                      _best20 = _smiling = _eyesOpen = _bestFirst = _hideBlurry = false;
                      _category = null;
                      if (_dates != null || (widget.tripId != null && _tripId == null)) {
                        _dates = null;
                        _tripId = widget.tripId;
                        _load();
                      }
                    }),
                    child: const Text('Reset'),
                  ),
              ]),
              const SizedBox(height: 12),
              Text('Best shots', style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                chip(Icons.workspace_premium_outlined, 'Best 20', _best20, (v) => _best20 = v),
                chip(Icons.auto_awesome, 'Best first', _bestFirst, (v) => _bestFirst = v),
                chip(Icons.sentiment_very_satisfied_outlined, 'Smiling', _smiling, (v) => _smiling = v),
                chip(Icons.visibility_outlined, 'Eyes open', _eyesOpen, (v) => _eyesOpen = v),
                chip(Icons.blur_off, 'Hide blurry', _hideBlurry, (v) => _hideBlurry = v),
              ]),
              const SizedBox(height: 18),
              Text('Which photos', style: text.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _categoryChip(),
                DateChip(
                  value: _dates,
                  onChanged: (d) => set(() {
                    _dates = d;
                    _load();
                  }),
                ),
                if (widget.tripId != null)
                  chip(Icons.luggage_outlined, 'This trip only', _tripId != null, (v) {
                    _tripId = v ? widget.tripId : null;
                    _load();
                  }),
              ]),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Show ${_visible.length} photos'),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }
}

/// Photo grid with drag-to-select: long-press a photo, then slide across
/// others to select (or deselect) them all, with a tick of haptics for each.
class _PhotoGrid extends StatefulWidget {
  const _PhotoGrid({
    required this.photos,
    required this.selected,
    required this.choosing,
    required this.onChanged,
    required this.onOpen,
  });

  final List<PersonPhoto> photos;
  final Set<String> selected;

  /// In "Choose photos" mode a tap selects/deselects instead of opening.
  final bool choosing;
  final VoidCallback onChanged;
  final ValueChanged<int> onOpen;

  @override
  State<_PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<_PhotoGrid> {
  static const _gap = 3.0;
  static const _pad = 3.0;
  final _scroll = ScrollController();

  int? _anchor;
  int? _last;
  bool _adding = true;
  Set<String> _before = {};
  Timer? _autoScroll;
  double _autoSpeed = 0;
  Offset _finger = Offset.zero;
  int _columns = 3;
  double _tile = 100;

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int? _indexAt(Offset local) {
    final y = local.dy + _scroll.offset - _pad;
    final x = local.dx - _pad;
    if (x < 0 || y < 0) return null;
    final col = (x / (_tile + _gap)).floor().clamp(0, _columns - 1);
    final row = (y / (_tile + _gap)).floor();
    final i = row * _columns + col;
    return i < widget.photos.length ? i : null;
  }

  void _start(Offset local) {
    final i = _indexAt(local);
    if (i == null) return;
    Haptics.lift();
    _anchor = _last = i;
    _before = {...widget.selected};
    _adding = !widget.selected.contains(widget.photos[i].assetId);
    _applyRange(i);
  }

  void _move(Offset local, double height) {
    _finger = local;
    _updateSelection();
    // Scroll when the finger nears the top or bottom edge.
    const edge = 70.0;
    _autoSpeed = local.dy < edge
        ? -(edge - local.dy) / 4
        : local.dy > height - edge
            ? (local.dy - (height - edge)) / 4
            : 0;
    if (_autoSpeed != 0 && _autoScroll == null) {
      _autoScroll = Timer.periodic(16.ms, (_) {
        final pos = _scroll.position;
        final next = (_scroll.offset + _autoSpeed)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
        _scroll.jumpTo(next);
        _updateSelection();
      });
    } else if (_autoSpeed == 0) {
      _stopAutoScroll();
    }
  }

  void _updateSelection() {
    final i = _indexAt(_finger);
    if (i == null || i == _last || _anchor == null) return;
    _last = i;
    Haptics.tick();
    _applyRange(i);
  }

  void _applyRange(int to) {
    final lo = _anchor! < to ? _anchor! : to;
    final hi = _anchor! < to ? to : _anchor!;
    widget.selected
      ..clear()
      ..addAll(_before);
    for (var k = lo; k <= hi; k++) {
      final id = widget.photos[k].assetId;
      _adding ? widget.selected.add(id) : widget.selected.remove(id);
    }
    widget.onChanged();
  }

  void _end() {
    _anchor = _last = null;
    _stopAutoScroll();
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.photos.isEmpty) {
      return const EmptyIllustration(message: 'No photos match these filters.');
    }
    return LayoutBuilder(builder: (context, box) {
      _columns = (box.maxWidth / 120).floor().clamp(3, 8);
      _tile = (box.maxWidth - 2 * _pad - (_columns - 1) * _gap) / _columns;
      final selecting = widget.choosing;
      return GestureDetector(
        onLongPressStart: (d) => _start(d.localPosition),
        onLongPressMoveUpdate: (d) => _move(d.localPosition, box.maxHeight),
        onLongPressEnd: (_) => _end(),
        onLongPressCancel: _end,
        child: GridView.builder(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(
              _pad, _pad, _pad, MediaQuery.paddingOf(context).bottom + _pad),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _columns,
            mainAxisSpacing: _gap,
            crossAxisSpacing: _gap,
          ),
          itemCount: widget.photos.length,
          itemBuilder: (context, i) {
            final photo = widget.photos[i];
            final isSelected = widget.selected.contains(photo.assetId);
            return GestureDetector(
              onTap: () {
                if (selecting) {
                  Haptics.tick();
                  isSelected
                      ? widget.selected.remove(photo.assetId)
                      : widget.selected.add(photo.assetId);
                  widget.onChanged();
                } else {
                  widget.onOpen(i);
                }
              },
              child: Stack(fit: StackFit.expand, children: [
                AnimatedScale(
                  scale: selecting && isSelected ? 0.88 : 1,
                  duration: 180.ms,
                  curve: Curves.easeOut,
                  child: AnimatedOpacity(
                    // Photos left out of the send are dimmed.
                    opacity: selecting && !isSelected ? 0.4 : 1,
                    duration: 180.ms,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(selecting && isSelected ? 14 : 4),
                      child: Hero(
                        tag: 'photo-${photo.assetId}',
                        child: AssetThumb(id: photo.assetId),
                      ),
                    ),
                  ),
                ),
                // While choosing, this opens the photo full screen.
                if (selecting)
                  Positioned(
                    left: 2,
                    bottom: 2,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'View',
                      onPressed: () => widget.onOpen(i),
                      icon: const Icon(Icons.open_in_full_rounded,
                          color: Colors.white, size: 18,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                    ),
                  ),
                if (photo.isBlurry && !selecting)
                  const Positioned(
                    left: 6,
                    bottom: 6,
                    child: Icon(Icons.blur_on, color: Colors.white70, size: 18),
                  ),
                AnimatedOpacity(
                  opacity: selecting ? 1 : 0,
                  duration: 150.ms,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: AnimatedSwitcher(
                        duration: 150.ms,
                        transitionBuilder: (c, a) =>
                            ScaleTransition(scale: a, child: c),
                        child: Icon(
                          isSelected ? Icons.check_circle : Icons.circle_outlined,
                          key: ValueKey(isSelected),
                          color: isSelected ? scheme.primary : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            );
          },
        ),
      );
    });
  }
}

class _FacesGrid extends StatelessWidget {
  const _FacesGrid({
    required this.faces,
    required this.leaving,
    required this.onTap,
    required this.onLongPress,
  });

  final List<FaceThumb> faces;
  final Set<int> leaving;
  final ValueChanged<FaceThumb> onTap;

  /// Long-press makes this face the person's cover photo.
  final ValueChanged<FaceThumb> onLongPress;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('Tap a face that isn\'t this person to remove it. Long-press to make it the cover.',
            style: Theme.of(context).textTheme.bodySmall),
      ),
      Expanded(
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(8, 8, 8, MediaQuery.paddingOf(context).bottom + 8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 80,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: faces.length,
          itemBuilder: (context, i) {
            final face = faces[i];
            final gone = leaving.contains(face.id);
            return GestureDetector(
              key: ValueKey(face.id),
              onTap: gone ? null : () => onTap(face),
              onLongPress: gone ? null : () => onLongPress(face),
              child: AnimatedSlide(
                offset: gone ? const Offset(0, -1.2) : Offset.zero,
                duration: 400.ms,
                curve: Curves.easeInBack,
                child: AnimatedScale(
                  scale: gone ? 0.2 : 1,
                  duration: 400.ms,
                  curve: Curves.easeInBack,
                  child: AnimatedOpacity(
                    opacity: gone ? 0 : 1,
                    duration: 400.ms,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(face.thumb, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

enum _SendState { idle, working, done }

/// A pill button that shrinks into a progress ring while photos are
/// prepared, flashes a tick, then returns.
class _SendButton extends StatefulWidget {
  const _SendButton(
      {required this.label, required this.enabled, required this.onSend});

  final String label;
  final bool enabled;
  final Future<void> Function() onSend;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  _SendState _state = _SendState.idle;

  Future<void> _tap() async {
    setState(() => _state = _SendState.working);
    try {
      await widget.onSend();
    } finally {
      if (mounted) {
        Haptics.success();
        setState(() => _state = _SendState.done);
      }
    }
    await Future<void>.delayed(1200.ms);
    if (mounted) setState(() => _state = _SendState.idle);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final idle = _state == _SendState.idle;
    final enabled = widget.enabled && idle;
    return LayoutBuilder(builder: (context, box) {
      // heightFactor 1: only as tall as the button, never the whole screen
      // (the bottom bar is given the full screen height to lay out in).
      return Center(
        heightFactor: 1,
        child: AnimatedContainer(
          duration: 350.ms,
          curve: Curves.easeInOutCubic,
          width: idle ? box.maxWidth : 56,
          height: 56,
          decoration: BoxDecoration(
            color: _state == _SendState.done
                ? Colors.green
                : enabled || !idle
                    ? scheme.primary
                    : scheme.onSurface.withAlpha(30),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: enabled ? _tap : null,
              child: Center(
                child: AnimatedSwitcher(
                  duration: 250.ms,
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: switch (_state) {
                    _SendState.idle => FittedBox(
                        key: const ValueKey('label'),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.send_rounded, color: scheme.onPrimary),
                          const SizedBox(width: 10),
                          Text(widget.label,
                              style: TextStyle(
                                  color: scheme.onPrimary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16)),
                        ]),
                      ),
                    _SendState.working => SizedBox.square(
                        key: const ValueKey('ring'),
                        dimension: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: scheme.onPrimary),
                      ),
                    _SendState.done => const Icon(Icons.check_rounded,
                        key: ValueKey('done'), color: Colors.white, size: 30),
                  },
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}
