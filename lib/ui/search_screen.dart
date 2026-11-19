import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'anim.dart';

import '../data/db.dart';
import '../data/gazetteer.dart';
import '../data/search.dart';
import '../face/tags.dart' show labelPrefix;
import '../scan/scan_controller.dart';
import 'aurora.dart';
import 'desktop_layout.dart';
import 'explore_screen.dart' show builtInCategories, categoryIcon;
import 'gallery_view.dart';
import 'glass.dart';
import 'motion.dart';
import 'person_screen.dart';
import 'sections.dart';
import 'theme.dart';
import 'widgets.dart';

/// One search box for everything the app knows: "Maya and Leo at the
/// beach", "Goa selfies", "food June 2026". People, trips, categories,
/// scenes and dates are recognised as you type; the photos shown match all
/// of them.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.controller, this.initial = ''});

  final ScanController controller;
  final String initial;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  ScanController get c => widget.controller;
  late final _text = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  SearchVocabulary? _vocab;
  List<PersonSummary> _people = const [];
  List<TripSummary> _trips = const [];
  List<String> _scenes = const [];
  List<SearchTerm> _terms = const [];
  List<String> _unknown = const [];
  List<SearchTerm> _suggestions = const [];
  Timer? _debounce;

  /// Desktop: searches made before (newest first), and how many photos
  /// the current one found.
  List<String> _recent = const [];
  int? _count;
  static const _recentKey = 'search_recent';

  @override
  void initState() {
    super.initState();
    _load();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final saved = await c.db.setting(_recentKey);
    if (!mounted || saved == null || saved.isEmpty) return;
    setState(() => _recent = saved.split('\n'));
  }

  /// Remembers the search in the box (the last eight).
  void _remember() {
    final q = [for (final t in _terms) t.label].join(' ').trim();
    if (q.isEmpty) return;
    _recent = [q, for (final r in _recent) if (r.toLowerCase() != q.toLowerCase()) r].take(8).toList();
    unawaited(c.db.setSetting(_recentKey, _recent.join('\n')));
  }

  @override
  void dispose() {
    _remember();
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final people = await c.db.people();
    final trips = await c.db.trips();
    final counts = await c.db.tagCounts();
    final builtIn = builtInCategories;
    final scenes = [
      for (final e in counts.entries.toList()..sort((a, b) => b.value.count.compareTo(a.value.count)))
        if (e.key.startsWith(labelPrefix)) e.key,
    ];
    SearchVocabulary vocabWith(PlaceIndex where) => SearchVocabulary(
          people: [
            for (final p in people)
              if (p.name != null) (id: p.id, name: p.name!, nickname: p.nickname),
          ],
          trips: [for (final t in trips) (id: t.id, name: t.name)],
          places: [for (final p in where.places) (name: p.name, spellings: p.spellings, photos: p.photos)],
          countries: where.countries,
          tags: {
            for (final e in builtIn.entries)
              if (counts.containsKey(e.key)) e.key: e.value,
            for (final s in scenes) s: s.substring(labelPrefix.length),
          },
        );
    final vocab = vocabWith(PlaceIndex.empty);
    // Place names come a moment later (worked out from the offline list).
    placeIndex(c.db, revision: c.revision).then((where) {
      if (!mounted || where.places.isEmpty) return;
      setState(() => _vocab = vocabWith(where));
      _parse();
    }).catchError((Object e) => debugPrint('Place names failed: $e'));
    if (!mounted) return;
    setState(() {
      _vocab = vocab;
      _people = [for (final p in people) if (p.name != null) p];
      _trips = trips;
      _scenes = [for (final s in scenes.take(12)) s.substring(labelPrefix.length)];
    });
    _parse();
  }

  void _onType(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), _parse);
    setState(() => _suggestions = _vocab?.suggest(_text.text) ?? const []);
  }

  void _parse() {
    final vocab = _vocab;
    if (vocab == null || !mounted) return;
    final r = vocab.parse(_text.text);
    final changed = r.terms.map((t) => t.key).join('|') != _terms.map((t) => t.key).join('|');
    setState(() {
      if (changed) _count = null;
      _terms = r.terms;
      _unknown = r.unknown;
      _suggestions = vocab.suggest(_text.text);
    });
  }

  void _setQuery(String q) {
    _text.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    _parse();
  }

  /// Adds [word], or finishes the last word typed with it.
  void _append(String word, {bool replaceLast = false}) {
    Haptics.tick();
    var q = _text.text.trimRight();
    if (replaceLast) {
      final cut = q.lastIndexOf(RegExp(r'\s'));
      q = cut < 0 ? '' : q.substring(0, cut);
    }
    _setQuery('${q.isEmpty ? '' : '$q '}$word ');
  }

  void _remove(SearchTerm t) {
    Haptics.tick();
    _setQuery([for (final k in _terms) if (k != t) k.label, ..._unknown].join(' '));
  }

  IconData _icon(SearchTerm t) => switch (t.kind) {
        TermKind.person => Icons.person_rounded,
        TermKind.trip => Icons.luggage_rounded,
        TermKind.dates => Icons.calendar_month_rounded,
        TermKind.place => Icons.place_rounded,
        TermKind.gender => t.gender == Gender.male ? Icons.male_rounded : Icons.female_rounded,
        TermKind.tag => categoryIcon(t.tag!),
      };

  /// Desktop keys in the box: Tab fills in the first suggestion; Esc clears
  /// the box, then (empty) goes back.
  KeyEventResult _boxKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.tab && _suggestions.isNotEmpty) {
      _append(_suggestions.first.label, replaceLast: true);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (_text.text.isNotEmpty) {
        _setQuery('');
      } else {
        Navigator.maybePop(context);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Desktop, like Spotlight: one big field, what it understood as chips
  /// that wrap, then the photos; before typing, recent searches, people,
  /// places and trips to start from.
  Widget _desktop(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final searching = _terms.isNotEmpty;
    final field = Focus(
      onKeyEvent: _boxKey,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _onType,
        onSubmitted: (_) {
          _parse();
          _remember();
          _focus.requestFocus();
        },
        style: const TextStyle(fontSize: TextSize.headline),
        decoration: InputDecoration(
          hintText: 'Search people, places, trips, dates…',
          hintStyle: TextStyle(fontSize: TextSize.headline, color: scheme.onSurfaceVariant),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 14, right: 8),
            child: Icon(Icons.search_rounded, size: 22, color: scheme.onSurfaceVariant),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          suffixIcon: _text.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear (Esc)',
                  icon: const Icon(Icons.cancel_rounded, size: 18),
                  onPressed: () => _setQuery(''),
                ),
          fillColor: Mac.card(context),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Mac.hairline(context))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Mac.hairline(context))),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7), width: 2),
          ),
        ),
      ),
    );
    final chips = <Widget>[
      for (final t in _terms)
        CapsuleChip(
          icon: _icon(t),
          label: t.label,
          selected: true,
          onTap: t.personId == null
              ? null
              : () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => PersonScreen(controller: c, personId: t.personId!)),
                  ),
          onDeleted: () => _remove(t),
        ).animate(key: ValueKey(t.key)).fadeIn(duration: 160.ms),
      for (final (i, sug) in _suggestions.indexed)
        Tooltip(
          message: i == 0 ? 'Tab to add' : '',
          child: CapsuleChip(
            outlined: true,
            icon: _icon(sug),
            label: sug.label,
            onTap: () => _append(sug.label, replaceLast: true),
          ),
        ),
    ];
    final pad = DesktopLayout.pad(context, const EdgeInsets.fromLTRB(16, 0, 24, 0), max: 920);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: pad.copyWith(top: 18, bottom: 10),
          child: Row(children: [
            GlassIconButton(
              tooltip: 'Back (Esc)',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.maybePop(context),
            ),
            const SizedBox(width: 10),
            Expanded(child: field),
          ]),
        ),
        if (chips.isNotEmpty)
          Padding(
            padding: pad.copyWith(left: pad.left + 44, bottom: 8),
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: chips),
          ),
        if (_unknown.isNotEmpty)
          Padding(
            padding: pad.copyWith(left: pad.left + 48, bottom: 8),
            child: Text(
              'Not sure what "${_unknown.join(' ')}" is. Try a name, a place like beach, a trip or a month.',
              style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant),
            ),
          ),
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 4, 28, 6),
            child: Text(
              _count == null ? 'Searching…' : '$_count ${_count == 1 ? 'photo' : 'photos'}',
              style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Divider(height: 0.5, thickness: 0.5, color: Mac.hairline(context)),
        Expanded(
          child: _vocab == null
              ? const SizedBox.shrink()
              : searching
                  ? GalleryView(
                      key: ValueKey(_terms.map((t) => t.key).join('|')),
                      controller: c,
                      source: GallerySource.ids(() async {
                        final ids = await runSearch(c.db, _terms);
                        if (mounted) setState(() => _count = ids.length);
                        return ids;
                      }),
                      emptyMessage: 'No photos match all of these.',
                    )
                  : _deskIdeas(context),
        ),
      ]),
    );
  }

  /// Desktop, before typing: recent searches, then everyone, places &
  /// things and trips, each a click away.
  Widget _deskIdeas(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_people.isEmpty && _trips.isEmpty && _scenes.isEmpty) {
      return const EmptyIllustration(message: 'Scan some photos and you can search them by who\'s in them, '
          'what\'s in them, the trip and the date.');
    }
    Widget section(String title, Widget child) => Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Text(title, style: const TextStyle(fontSize: TextSize.callout, fontWeight: FontWeight.w700)),
            ),
            child,
          ]),
        );
    final examples = [
      if (_people.isNotEmpty) '${_people.first.name!.split(' ').first} selfies',
      if (_scenes.isNotEmpty) _scenes.first,
      if (_people.length >= 2) '${_people[0].name!.split(' ').first} and ${_people[1].name!.split(' ').first}',
      if (_trips.isNotEmpty) _trips.first.name,
    ];
    return ListView(
      padding: DesktopLayout.pad(context, const EdgeInsets.fromLTRB(28, 4, 28, 32), max: 920),
      children: [
        if (_recent.isNotEmpty)
          section(
            'Recent',
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _recent)
                CapsuleChip(icon: Icons.history_rounded, label: r, onTap: () => _setQuery('$r ')),
            ]),
          ),
        if (_people.isNotEmpty)
          section(
            'People',
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final p in _people.take(24)) _PersonChoice(person: p, onTap: () => _append(p.name!)),
            ]),
          ),
        if (_scenes.isNotEmpty)
          section(
            'Places & things',
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in _scenes)
                CapsuleChip(icon: categoryIcon('$labelPrefix$s'), label: s, onTap: () => _append(s)),
            ]),
          ),
        if (_trips.isNotEmpty)
          section(
            'Trips',
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in _trips) CapsuleChip(icon: Icons.luggage_rounded, label: t.name, onTap: () => _append(t.name)),
            ]),
          ),
        if (examples.isNotEmpty)
          section(
            'Try mixing them',
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in examples)
                CapsuleChip(outlined: true, icon: Icons.auto_awesome_rounded, label: e, onTap: () => _setQuery('$e ')),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Text('Tab adds the first suggestion · Esc clears the box',
              style: TextStyle(fontSize: TextSize.small, color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopLayout.on) return _desktop(context);
    final scheme = Theme.of(context).colorScheme;
    final searching = _terms.isNotEmpty;
    return Aurora(
      intensity: 0.5,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: DesktopLayout.pad(context, const EdgeInsets.fromLTRB(4, 8, 16, 8)),
              child: Row(children: [
                const BackButton(),
                Expanded(
                  child: Container(
                    height: textHeight(context, 44),
                    decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(14)),
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      autofocus: widget.initial.isEmpty,
                      textInputAction: TextInputAction.search,
                      onChanged: _onType,
                      onSubmitted: (_) {
                        _parse();
                        _remember();
                      },
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'People, places, trips, dates',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _text.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.cancel_rounded, size: 20),
                                onPressed: () => _setQuery(''),
                              ),
                        contentPadding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            if (_terms.isNotEmpty || _suggestions.isNotEmpty)
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: DesktopLayout.pad(context, const EdgeInsets.symmetric(horizontal: 12)),
                  children: [
                    for (final t in _terms)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Center(
                          child: CapsuleChip(
                            icon: _icon(t),
                            label: t.label,
                            selected: true,
                            onTap: t.personId == null
                                ? null
                                : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => PersonScreen(controller: c, personId: t.personId!)),
                                    ),
                            onDeleted: () => _remove(t),
                          ),
                        ),
                      ).animate(key: ValueKey(t.key)).fadeIn(duration: 200.ms).scaleXY(begin: 0.85),
                    for (final s in _suggestions)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Center(
                          child: CapsuleChip(
                            outlined: true,
                            icon: _icon(s),
                            label: s.label,
                            onTap: () => _append(s.label, replaceLast: true),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (_unknown.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                child: Text(
                  'Not sure what "${_unknown.join(' ')}" is. Try a name, a place like beach, a trip or a month.',
                  style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurfaceVariant),
                ),
              ),
            Expanded(
              child: _vocab == null
                  ? const SizedBox.shrink()
                  : searching
                      ? GalleryView(
                          key: ValueKey(_terms.map((t) => t.key).join('|')),
                          controller: c,
                          source: GallerySource.ids(() => runSearch(c.db, _terms)),
                          emptyMessage: 'No photos match all of these.',
                        )
                      : _ideas(context),
            ),
          ]),
        ),
      ),
    );
  }

  /// Before typing: people, places and trips to start from.
  Widget _ideas(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_people.isEmpty && _trips.isEmpty && _scenes.isEmpty) {
      return const EmptyIllustration(message: 'Scan some photos and you can search them by who\'s in them, '
          'what\'s in them, the trip and the date.');
    }
    Widget chips(List<Widget> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: children),
        );
    return ListView(padding: DesktopLayout.pad(context, EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24)), children: [
      if (_recent.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionHeader(title: 'Recent', top: 12)),
        chips([
          for (final r in _recent) CapsuleChip(icon: Icons.history_rounded, label: r, onTap: () => _setQuery('$r ')),
        ]),
      ],
      if (_people.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionHeader(title: 'People', top: 12)),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final p in _people.take(20))
                Pressable(
                  onTap: () => _append(p.name!),
                  child: SizedBox(
                    width: 72,
                    child: Column(children: [
                      FaceAvatar(personId: p.id, thumb: p.coverThumb, radius: 28, hero: false),
                      const SizedBox(height: 6),
                      Text(p.name!.split(' ').first,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: TextSize.caption, color: scheme.onSurface)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ],
      if (_scenes.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionHeader(title: 'Places & things')),
        chips([
          for (final s in _scenes)
            CapsuleChip(icon: categoryIcon('$labelPrefix$s'), label: s, onTap: () => _append(s)),
        ]),
      ],
      if (_trips.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionHeader(title: 'Trips')),
        chips([
          for (final t in _trips) CapsuleChip(icon: Icons.luggage_rounded, label: t.name, onTap: () => _append(t.name)),
        ]),
      ],
      const Padding(
        padding: EdgeInsets.only(top: 16),
        child: SectionFooter('Mix them: "Maya and Leo beach", "Goa selfies", "food June 2026".'),
      ),
    ]);
  }
}

/// Desktop Search: a person to add to the search, as a small card with
/// their face, name and how many photos they're in.
class _PersonChoice extends StatefulWidget {
  const _PersonChoice({required this.person, required this.onTap});

  final PersonSummary person;
  final VoidCallback onTap;

  @override
  State<_PersonChoice> createState() => _PersonChoiceState();
}

class _PersonChoiceState extends State<_PersonChoice> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 184,
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
          decoration: BoxDecoration(
            color: _hover ? Mac.hover(context) : Mac.card(context),
            borderRadius: BorderRadius.circular(Mac.cardRadius),
            border: Border.all(color: Mac.hairline(context), width: 0.5),
          ),
          child: Row(children: [
            FaceAvatar(personId: p.id, thumb: p.coverThumb, radius: 18, hero: false),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: TextSize.caption, fontWeight: FontWeight.w600)),
                Text('${p.photoCount} photos', style: TextStyle(fontSize: TextSize.tiny, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
