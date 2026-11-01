import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'aurora.dart';
import 'motion.dart';
import 'widgets.dart';

/// Faces the app couldn't place with anyone (half turned, partly hidden,
/// blurry): pick some and move them to a person by hand.
class UnmatchedScreen extends StatefulWidget {
  const UnmatchedScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<UnmatchedScreen> createState() => _UnmatchedScreenState();
}

class _UnmatchedScreenState extends State<UnmatchedScreen> {
  ScanController get c => widget.controller;
  List<FaceThumb>? _faces;
  final Set<int> _picked = {};

  /// Faces flying off after a move.
  final Set<int> _leaving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final faces = await c.db.unmatchedFaces();
    if (mounted) setState(() => _faces = faces);
  }

  void _toggle(FaceThumb f) {
    Haptics.tick();
    setState(() => _picked.contains(f.id) ? _picked.remove(f.id) : _picked.add(f.id));
  }

  /// The whole photo, to tell who a half face is.
  void _peek(FaceThumb f) {
    Haptics.lift();
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: AspectRatio(aspectRatio: 1, child: AssetThumb(id: f.assetId, size: 800)),
      ),
    );
  }

  Future<void> _move() async {
    final ids = _picked.toList();
    final person = await pickPerson(context, c, title: ids.length == 1 ? 'Who is this?' : 'Who are these ${ids.length}?');
    if (person == null || !mounted) return;
    final undo = await c.db.assignFaces(ids, person.id);
    Haptics.success();
    setState(() {
      _leaving.addAll(ids);
      _picked.clear();
    });
    await Future<void>.delayed(350.ms);
    if (!mounted) return;
    setState(() {
      _faces = [for (final f in _faces!) if (!ids.contains(f.id)) f];
      _leaving.removeAll(ids);
    });
    c.changed();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('${ids.length == 1 ? 'Face' : '${ids.length} faces'} moved to ${person.name}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await c.db.restore(undo);
            c.changed();
            await _load();
          },
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final faces = _faces;
    final scheme = Theme.of(context).colorScheme;
    return Aurora(
      intensity: 0.5,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(_picked.isEmpty ? 'Unmatched faces' : '${_picked.length} picked'),
          actions: [
            if (_picked.isNotEmpty)
              TextButton(onPressed: () => setState(_picked.clear), child: const Text('Clear')),
          ],
        ),
        body: faces == null
            ? const Center(child: CircularProgressIndicator())
            : faces.isEmpty
                ? const EmptyIllustration(message: 'Every face belongs to someone.')
                : CustomScrollView(slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Text(
                          'Faces ShareBro couldn\'t match with anyone, often half turned or partly hidden. '
                          'Tap the ones that belong together, then move them. Hold one to see the whole photo.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.paddingOf(context).bottom + 96),
                      sliver: SliverGrid.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 110,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                        ),
                        itemCount: faces.length,
                        itemBuilder: (context, i) {
                          final f = faces[i];
                          return _FaceCell(
                            face: f,
                            picked: _picked.contains(f.id),
                            leaving: _leaving.contains(f.id),
                            onTap: () => _toggle(f),
                            onLongPress: () => _peek(f),
                          );
                        },
                      ),
                    ),
                  ]),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
        floatingActionButton: AnimatedSlide(
          offset: _picked.isEmpty ? const Offset(0, 2) : Offset.zero,
          duration: 250.ms,
          curve: Curves.easeOutCubic,
          child: FloatingActionButton.extended(
            onPressed: _picked.isEmpty ? null : _move,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(_picked.length > 1 ? 'Move ${_picked.length} to…' : 'Move to…'),
          ),
        ),
      ),
    );
  }
}

class _FaceCell extends StatelessWidget {
  const _FaceCell({
    required this.face,
    required this.picked,
    required this.leaving,
    required this.onTap,
    required this.onLongPress,
  });

  final FaceThumb face;
  final bool picked, leaving;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: leaving ? 0 : 1,
      duration: 300.ms,
      child: AnimatedScale(
        scale: leaving ? 0.4 : (picked ? 0.88 : 1),
        duration: 220.ms,
        curve: Curves.easeOutCubic,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(fit: StackFit.expand, children: [
            AnimatedContainer(
              duration: 180.ms,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: picked ? scheme.primary : Colors.transparent, width: 3),
              ),
              padding: const EdgeInsets.all(3),
              child: ClipOval(child: Image.memory(face.thumb, fit: BoxFit.cover, gaplessPlayback: true)),
            ),
            if (picked)
              Positioned(
                right: 2,
                bottom: 2,
                child: CircleAvatar(
                  radius: 12,
                  backgroundColor: scheme.primary,
                  child: Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary),
                ).animate().scaleXY(begin: 0.3, duration: 200.ms, curve: Curves.easeOutBack),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Asks who: type to filter the people, tap one, or make a new person with
/// the typed name. Returns the person's id and name.
Future<({int id, String name})?> pickPerson(BuildContext context, ScanController c, {required String title}) {
  return showModalBottomSheet<({int id, String name})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _PersonPicker(controller: c, title: title),
  );
}

class _PersonPicker extends StatefulWidget {
  const _PersonPicker({required this.controller, required this.title});

  final ScanController controller;
  final String title;

  @override
  State<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<_PersonPicker> {
  final _query = TextEditingController();
  List<PersonSummary> _people = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.db.people().then((p) {
      if (mounted) setState(() => _people = p);
    });
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _create(String name) async {
    final id = await widget.controller.db.createPerson(name);
    if (mounted) Navigator.pop(context, (id: id, name: name));
  }

  @override
  Widget build(BuildContext context) {
    final typed = _query.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final q = typed.toLowerCase();
    final matches = [
      for (final p in _people)
        if (q.isEmpty ||
            p.displayName.toLowerCase().contains(q) ||
            (p.nickname?.toLowerCase().contains(q) ?? false))
          p,
    ];
    final exact = _people.any((p) => p.name?.toLowerCase() == q);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _query,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search or type a new name',
              ),
              // Done picks the only match, or makes the typed name.
              onSubmitted: (_) {
                if (matches.length == 1) {
                  Navigator.pop(context, (id: matches.single.id, name: matches.single.displayName));
                } else if (typed.isNotEmpty && !exact) {
                  _create(typed);
                }
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              if (typed.isNotEmpty && !exact)
                ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
                  title: Text('New person "$typed"'),
                  onTap: () => _create(typed),
                ),
              for (final p in matches)
                ListTile(
                  leading: FaceAvatar(personId: p.id, thumb: p.coverThumb, radius: 20, hero: false),
                  title: Text(p.displayName),
                  subtitle: Text('${p.photoCount} photos'),
                  onTap: () => Navigator.pop(context, (id: p.id, name: p.displayName)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
