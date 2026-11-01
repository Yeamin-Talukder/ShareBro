import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../data/search.dart';
import '../face/tags.dart' show labelPrefix;
import '../scan/scan_controller.dart';
import 'aurora.dart';
import 'explore_screen.dart' show builtInCategories, categoryIcon;
import 'gallery_view.dart';
import 'motion.dart';
import 'person_screen.dart';
import 'sections.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
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
    final vocab = SearchVocabulary(
      people: [
        for (final p in people)
          if (p.name != null) (id: p.id, name: p.name!, nickname: p.nickname),
      ],
      trips: [for (final t in trips) (id: t.id, name: t.name)],
      tags: {
        for (final e in builtIn.entries)
          if (counts.containsKey(e.key)) e.key: e.value,
        for (final s in scenes) s: s.substring(labelPrefix.length),
      },
    );
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
    setState(() {
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
        TermKind.tag => categoryIcon(t.tag!),
      };

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(children: [
                const BackButton(),
                Expanded(
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(color: capsuleFill(context), borderRadius: BorderRadius.circular(14)),
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      autofocus: widget.initial.isEmpty,
                      textInputAction: TextInputAction.search,
                      onChanged: _onType,
                      onSubmitted: (_) => _parse(),
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
                  padding: const EdgeInsets.symmetric(horizontal: 12),
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
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
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
    return ListView(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24), children: [
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
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
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
