import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'gallery_view.dart';
import 'motion.dart';

/// Pick two or more people and see only the photos they're all in.
class TogetherScreen extends StatefulWidget {
  const TogetherScreen({
    super.key,
    required this.controller,
    this.tripId,
    this.initial = const {},
  });

  final ScanController controller;
  final int? tripId;
  final Set<int> initial;

  @override
  State<TogetherScreen> createState() => _TogetherScreenState();
}

class _TogetherScreenState extends State<TogetherScreen> {
  ScanController get c => widget.controller;
  List<PersonSummary> _people = const [];
  late final Set<int> _picked = {...widget.initial};

  @override
  void initState() {
    super.initState();
    c.db.people(tripId: widget.tripId).then((p) {
      if (mounted) setState(() => _people = p);
    });
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('Together')),
      body: Column(children: [
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final p in _people)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    avatar: CircleAvatar(
                      backgroundImage:
                          p.coverThumb == null ? null : MemoryImage(p.coverThumb!),
                    ),
                    label: Text(p.displayName),
                    selected: _picked.contains(p.id),
                    onSelected: (v) {
                      Haptics.tick();
                      setState(() => v ? _picked.add(p.id) : _picked.remove(p.id));
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: 300.ms,
            child: picked.length < 2
                ? Center(
                    key: const ValueKey('hint'),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Pick two or more people to see the photos they\'re all in.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  )
                : GalleryView(
                    key: ValueKey(picked.join(',')),
                    controller: c,
                    source: GallerySource.ids(
                        () => c.db.photosWithAll(picked, tripId: widget.tripId)),
                    emptyMessage: 'No photos with all of them together yet.',
                  ),
          ),
        ),
      ]),
    );
  }
}
