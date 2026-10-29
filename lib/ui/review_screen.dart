import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../scan/scan_controller.dart';
import 'motion.dart';
import 'aurora.dart';
import 'widgets.dart';

/// Swipe through faces nobody has confirmed yet: right = yes / save name,
/// left = skip.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  ScanController get c => widget.controller;
  List<ReviewItem>? _items;
  List<String> _names = const [];
  int _index = 0;
  final _cardKey = GlobalKey<_SwipeCardState>();
  final _nameField = TextEditingController();
  int _shakeName = 0;

  /// Yes/Save answers in a row; shown as a streak badge from 3.
  int _streak = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameField.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await c.reviewQueue();
    final names = [
      for (final p in await c.db.people())
        if (p.name != null) p.name!,
    ];
    if (!mounted) return;
    setState(() {
      _items = items;
      _names = names;
      _index = 0;
    });
  }

  ReviewItem? get _current =>
      _items != null && _index < _items!.length ? _items![_index] : null;

  /// Returns false to make the card spring back instead of leaving.
  Future<bool> _decide(bool yes) async {
    final item = _current;
    if (item == null) return false;
    switch (item) {
      case GroupReview():
        if (yes) {
          final name = _nameField.text.trim();
          if (name.isEmpty) {
            Haptics.warn();
            setState(() => _shakeName++);
            return false;
          }
          await c.db.renamePerson(item.person.id, name);
          if (!_names.contains(name)) _names = [..._names, name];
        } else {
          await c.db.skipGroup(item.person.id);
        }
      case FaceReview():
        if (yes) {
          await c.db.assignFace(item.faceId, item.person.id);
        } else {
          await c.db.markReviewed([item.faceId]);
        }
      case MergeReview(:final a, :final b):
        if (yes) {
          // Keep whichever has a name.
          final (into, from) = a.name == null && b.name != null
              ? (b, a)
              : (a, b);
          await c.db.mergePeople(into.id, [from.id]);
          // Later cards may mention the merged-away person; reload the deck.
          _reloadAfterCard = true;
        } else {
          await c.db.dismissPair(a.id, b.id);
        }
    }
    yes ? Haptics.success() : Haptics.tick();
    setState(() => _streak = yes ? _streak + 1 : 0);
    return true;
  }

  bool _reloadAfterCard = false;

  void _next() {
    _nameField.clear();
    c.changed();
    if (_reloadAfterCard) {
      _reloadAfterCard = false;
      _load();
      return;
    }
    setState(() => _index++);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Review faces'),
          bottom: items == null || items.isEmpty
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _index / items.length),
                    duration: 300.ms,
                    builder: (_, v, _) => LinearProgressIndicator(value: v),
                  ),
                ),
        ),
        body: items == null
            ? const Center(child: CircularProgressIndicator())
            : _current == null
            ? _done(context)
            : _deck(context, items),
      ),
    );
  }

  Widget _deck(BuildContext context, List<ReviewItem> items) {
    final item = _current!;
    final next = _index + 1 < items.length ? items[_index + 1] : null;
    final after = _index + 2 < items.length ? items[_index + 2] : null;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${_index + 1} of ${items.length}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              if (_streak >= 3) ...[
                const SizedBox(width: 12),
                _StreakBadge(key: ValueKey(_streak), count: _streak),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            // A real-feeling deck: two cards peek out behind the top one, and
            // the next card lifts into place each time one is swiped away.
            child: Stack(
              children: [
                if (after != null)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(0, 22),
                      child: Transform.rotate(
                        angle: 0.03,
                        child: Transform.scale(
                          scale: 0.88,
                          child: Opacity(
                            opacity: 0.35,
                            child: _CardBody(item: after, preview: true),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (next != null)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: const Offset(0, 11),
                      child: Transform.rotate(
                        angle: -0.02,
                        child: Transform.scale(
                          scale: 0.94,
                          child: Opacity(
                            opacity: 0.6,
                            child: _CardBody(item: next, preview: true),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child:
                      _SwipeCard(
                            key: _cardKey,
                            // New key per item so each card starts centred.
                            id: _index,
                            onDecide: _decide,
                            onGone: _next,
                            child: _CardBody(
                              item: item,
                              nameField: _nameField,
                              names: _names,
                              shake: _shakeName,
                            ),
                          )
                          .animate(key: ValueKey('card$_index'))
                          .scaleXY(
                            begin: 0.94,
                            duration: 320.ms,
                            curve: Curves.easeOutBack,
                          )
                          .rotate(begin: -0.02 / 6.283, duration: 320.ms)
                          .moveY(
                            begin: 11,
                            duration: 320.ms,
                            curve: Curves.easeOutCubic,
                          ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RoundButton(
                  icon: Icons.close_rounded,
                  label: switch (item) {
                    GroupReview() => 'Skip',
                    MergeReview() => 'Different',
                    FaceReview() => 'No',
                  },
                  color: Theme.of(context).colorScheme.error,
                  onTap: () => _cardKey.currentState?.fling(false),
                ),
                const SizedBox(width: 40),
                _RoundButton(
                  icon: Icons.check_rounded,
                  label: switch (item) {
                    GroupReview() => 'Save',
                    MergeReview() => 'Same',
                    FaceReview() => 'Yes',
                  },
                  color: Colors.green,
                  onTap: () => _cardKey.currentState?.fling(true),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              const ConfettiBurst(count: 20),
              CircleAvatar(
                radius: 48,
                backgroundColor: Colors.green,
                child: const Icon(
                  Icons.check_rounded,
                  size: 56,
                  color: Colors.white,
                ),
              ).animate().scale(
                begin: const Offset(0, 0),
                duration: 600.ms,
                curve: Curves.elasticOut,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'All caught up',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ).animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 8),
          const Text('Every face has been reviewed.')
              .animate()
              .fadeIn(delay: 300.ms),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ).animate().fadeIn(delay: 400.ms),
        ],
      ),
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.item,
    this.nameField,
    this.names = const [],
    this.shake = 0,
    this.preview = false,
  });

  final ReviewItem item;
  final TextEditingController? nameField;
  final List<String> names;
  final int shake;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: preview ? 0 : 6,
      shadowColor: Colors.black26,
      clipBehavior: Clip.antiAlias,
      child: switch (item) {
        MergeReview(:final a, :final b, :final facesA, :final facesB) => Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  for (final (person, faces) in [(a, facesA), (b, facesB)])
                    Expanded(
                      child: Column(
                        children: [
                          for (final f in faces.take(3))
                            Expanded(
                              child: Image.memory(
                                f.thumb,
                                fit: BoxFit.cover,
                                width: double.infinity,
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              '${person.displayName} · ${person.photoCount}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.labelLarge,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  const Icon(Icons.call_merge),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Same person?',
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        FaceReview(:final thumb, :final person, :final similarity) => Column(
          children: [
            Expanded(
              child: Image.memory(
                thumb,
                fit: BoxFit.cover,
                width: double.infinity,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  FaceAvatar(
                    personId: person.id,
                    thumb: person.coverThumb,
                    radius: 26,
                    hero: false,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Is this ${person.displayName}?',
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${(similarity * 100).round()}% match',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        GroupReview(:final person, :final faces) => Column(
          children: [
            Expanded(
              child: GridView.count(
                crossAxisCount: faces.length <= 1
                    ? 1
                    : (faces.length <= 4 ? 2 : 3),
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final f in faces)
                    Image.memory(f.thumb, fit: BoxFit.cover),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Who is this?',
                    style: text.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text('${person.photoCount} photos', style: text.bodySmall),
                  if (!preview && nameField != null) ...[
                    const SizedBox(height: 12),
                    TextField(
                          controller: nameField,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            hintText: 'Type a name',
                            filled: true,
                            fillColor: scheme.surfaceContainerHighest,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        )
                        .animate(key: ValueKey(shake), autoPlay: true)
                        .shakeX(
                          hz: 6,
                          amount: shake > 0 ? 6 : 0,
                          duration: 400.ms,
                        ),
                    if (names.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (final n in names)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ActionChip(
                                  label: Text(n),
                                  onPressed: () => nameField!.text = n,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      },
    );
  }
}

/// Drag sideways to decide; flies off screen or springs back.
class _SwipeCard extends StatefulWidget {
  const _SwipeCard({
    super.key,
    required this.id,
    required this.onDecide,
    required this.onGone,
    required this.child,
  });

  final int id;
  final Future<bool> Function(bool yes) onDecide;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_SwipeCard> createState() => _SwipeCardState();
}

class _SwipeCardState extends State<_SwipeCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: 350.ms,
  );
  Offset _drag = Offset.zero;
  Offset _from = Offset.zero, _to = Offset.zero;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(
      () => setState(() {
        _drag = Offset.lerp(
          _from,
          _to,
          Curves.easeOutCubic.transform(_anim.value),
        )!;
      }),
    );
  }

  @override
  void didUpdateWidget(covariant _SwipeCard old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      _anim.stop();
      _drag = Offset.zero;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _animateTo(Offset target) {
    _from = _drag;
    _to = target;
    return _anim.forward(from: 0);
  }

  Future<void> fling(bool yes) async {
    if (_busy) return;
    _busy = true;
    final width = MediaQuery.sizeOf(context).width;
    if (await widget.onDecide(yes)) {
      await _animateTo(Offset((yes ? 1.5 : -1.5) * width, _drag.dy + 40));
      widget.onGone();
    } else {
      await _animateTo(Offset.zero);
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final t = (_drag.dx / (width * 0.4)).clamp(-1.0, 1.0);
    return GestureDetector(
      onPanUpdate: _busy ? null : (d) => setState(() => _drag += d.delta),
      onPanEnd: _busy
          ? null
          : (d) {
              final fast = d.velocity.pixelsPerSecond.dx.abs() > 900;
              if (t.abs() > 0.6 || fast) {
                fling((fast ? d.velocity.pixelsPerSecond.dx : _drag.dx) > 0);
              } else {
                _animateTo(Offset.zero);
              }
            },
      child: Transform.translate(
        offset: _drag,
        child: Transform.rotate(
          angle: t * math.pi / 18,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      if (t != 0)
                        BoxShadow(
                          color: (t > 0 ? Colors.green : Colors.redAccent)
                              .withAlpha((t.abs() * 210).round()),
                          blurRadius: 34 * t.abs(),
                          spreadRadius: 4 * t.abs(),
                        ),
                    ],
                  ),
                  child: widget.child,
                ),
              ),
              Positioned(
                top: 24,
                left: 24,
                child: Opacity(
                  opacity: t.clamp(0.0, 1.0),
                  child: const _Stamp('YES', Colors.green, -0.25),
                ),
              ),
              Positioned(
                top: 24,
                right: 24,
                child: Opacity(
                  opacity: (-t).clamp(0.0, 1.0),
                  child: const _Stamp('SKIP', Colors.redAccent, 0.25),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stamp extends StatelessWidget {
  const _Stamp(this.text, this.color, this.angle);

  final String text;
  final Color color;
  final double angle;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 4),
          borderRadius: BorderRadius.circular(10),
          color: Colors.black26,
        ),
        child: Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 30,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          shape: CircleBorder(side: BorderSide(color: color, width: 2)),
          color: color.withAlpha(30),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Icon(icon, color: color, size: 34),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.labelLarge),
      ],
    );
  }
}

/// "🔥 5 in a row" — pops a little bigger with every extra yes.
class _StreakBadge extends StatelessWidget {
  const _StreakBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final boost = (count - 3).clamp(0, 7) * 0.04;
    return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '🔥 $count in a row',
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        )
        .animate()
        .scaleXY(
          begin: 0.6,
          end: 1 + boost,
          duration: 420.ms,
          curve: Curves.elasticOut,
        )
        .shake(hz: 4, rotation: 0.04, duration: 300.ms);
  }
}
