import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

import '../data/db.dart';
import 'motion.dart';
import 'widgets.dart';

/// How long each photo stays on screen.
const _slide = Duration(seconds: 4);

/// Most photos a reel plays.
const _reelLength = 30;

/// Full-screen slideshow of a person's best photos: each one slowly zooms
/// toward their face (Ken Burns), with story-style progress bars. Tap the
/// right or left side to skip, hold to pause, swipe down to close.
class ReelScreen extends StatefulWidget {
  ReelScreen({super.key, required this.person, required List<PersonPhoto> photos})
      : photos = ([...photos]..sort((a, b) => b.quality.compareTo(a.quality)))
            .take(_reelLength)
            .toList();

  final PersonSummary person;
  final List<PersonPhoto> photos;

  @override
  State<ReelScreen> createState() => _ReelScreenState();
}

class _ReelScreenState extends State<ReelScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(vsync: this, duration: _slide)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _go(1);
    })
    ..forward();
  int _i = 0;
  double _drag = 0;

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _go(int step) {
    final next = _i + step;
    if (next >= widget.photos.length) {
      Navigator.pop(context);
      return;
    }
    Haptics.tick();
    setState(() => _i = next.clamp(0, widget.photos.length - 1));
    _clock.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    if (photos.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.pop(context));
      return const SizedBox.shrink();
    }
    final photo = photos[_i];
    final progress = (_drag.clamp(0, 300) / 300).toDouble();
    return Scaffold(
      backgroundColor: Colors.black.withAlpha((255 * (1 - progress)).round()),
      body: GestureDetector(
        onTapUp: (d) => _go(d.localPosition.dx > MediaQuery.sizeOf(context).width / 3 ? 1 : -1),
        onLongPressStart: (_) => _clock.stop(),
        onLongPressEnd: (_) => _clock.forward(),
        onVerticalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dy).clamp(0, 400)),
        onVerticalDragEnd: (d) {
          if (_drag > 120 || (d.primaryVelocity ?? 0) > 800) {
            Navigator.pop(context);
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Transform.scale(
            scale: 1 - progress * 0.3,
            child: Stack(fit: StackFit.expand, children: [
              AnimatedSwitcher(
                duration: 700.ms,
                child: _KenBurns(
                  key: ValueKey(photo.assetId),
                  photo: photo,
                  clock: _clock,
                ),
              ),
              // Darken the top so the bars and name stay readable.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Column(children: [
                    Row(children: [
                      for (var k = 0; k < photos.length; k++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: AnimatedBuilder(
                                animation: _clock,
                                builder: (_, _) => LinearProgressIndicator(
                                  minHeight: 3,
                                  value: k < _i ? 1 : (k == _i ? _clock.value : 0),
                                  backgroundColor: Colors.white24,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      FaceAvatar(
                        personId: widget.person.id,
                        thumb: widget.person.coverThumb,
                        radius: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(widget.person.displayName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16)),
                      ),
                      Text('${_i + 1} / ${photos.length}',
                          style: const TextStyle(color: Colors.white70)),
                      IconButton(
                        color: Colors.white,
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ]),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A photo that slowly zooms in toward the person's face as [clock] runs.
class _KenBurns extends StatelessWidget {
  const _KenBurns({super.key, required this.photo, required this.clock});

  final PersonPhoto photo;
  final Animation<double> clock;

  @override
  Widget build(BuildContext context) {
    final f = photo.face.center;
    // Alignment of the face within the photo (-1..1), which is where we zoom.
    final focus = Alignment(f.dx * 2 - 1, f.dy * 2 - 1);
    return FutureBuilder<AssetEntity?>(
      future: AssetThumb.entity(photo.assetId),
      builder: (context, snap) {
        final asset = snap.data;
        if (asset == null) return const SizedBox.expand();
        return AnimatedBuilder(
          animation: clock,
          builder: (context, child) => Transform.scale(
            scale: 1.05 + 0.2 * Curves.easeInOut.transform(clock.value),
            alignment: focus,
            child: child,
          ),
          child: AssetEntityImage(
            asset,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize.square(1600),
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }
}
