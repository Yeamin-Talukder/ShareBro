import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:image_picker/image_picker.dart';

import '../data/db.dart';
import '../data/profile.dart';
import '../scan/scan_controller.dart';
import '../share/net.dart';
import 'aurora.dart';
import 'glass.dart';
import 'motion.dart';
import 'sections.dart';
import 'widgets.dart';

/// Your profile: your name on other phones and your face, set up once and
/// used wherever the app needs to recognise you (trip groups for now).
/// Selfies, uploaded photos (for phones and computers without a camera),
/// or your own face from People.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.controller});

  final ScanController controller;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ScanController get c => widget.controller;
  final _picker = ImagePicker();
  bool _busy = false;
  late String _name = c.sharing.identity.alias;

  bool get _hasCamera => _picker.supportsImageSource(ImageSource.camera);

  Future<void> _add(Future<List<XFile>> Function() pick, FaceSource source) async {
    List<XFile> files;
    try {
      files = await pick();
    } catch (e) {
      _toast('Couldn\'t open the ${source == FaceSource.selfie ? 'camera' : 'photos'}.');
      return;
    }
    if (files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final found = await c.addProfilePhotos([for (final f in files) f.path], source);
    if (!mounted) return;
    setState(() => _busy = false);
    if (found == 0) {
      Haptics.warn();
      _toast(files.length == 1
          ? 'No clear face in that one. Face the camera in good light.'
          : 'No clear face in those. Try photos where your face is big and sharp.');
      return;
    }
    Haptics.success();
    final missed = files.length - found;
    _toast('${found == 1 ? 'Added 1 photo' : 'Added $found photos'}'
        '${missed > 0 ? ' · $missed had no clear face' : ''}');
  }

  Future<void> _selfie() => _add(() async {
        final shot = await _picker.pickImage(
            source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxWidth: 1600, imageQuality: 92);
        return [?shot];
      }, FaceSource.selfie);

  Future<void> _upload() => _add(
      () => _picker.pickMultiImage(maxWidth: 1600, imageQuality: 92, limit: 10), FaceSource.upload);

  Future<void> _fromPeople() async {
    final people = [for (final p in await c.db.people()) if (p.name != null) p];
    if (!mounted) return;
    if (people.isEmpty) {
      _toast('Name yourself in People first, then pick yourself here.');
      return;
    }
    final pick = await showModalBottomSheet<PersonSummary>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text('Which one is you?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
            SectionCard.rows(rows: [
              for (final p in people)
                SectionRow(
                  leading: FaceAvatar(personId: p.id, thumb: p.coverThumb, radius: 18, hero: false),
                  title: p.name!,
                  subtitle: '${p.photoCount} photos',
                  onTap: () => Navigator.pop(context, p),
                ),
            ]),
          ]),
        ),
      ),
    );
    if (pick == null) return;
    setState(() => _busy = true);
    await c.profileFromPerson(pick.id);
    if (!mounted) return;
    setState(() => _busy = false);
    Haptics.success();
    _toast('Your face now comes from ${pick.name}\'s photos');
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove your face?'),
        content: const Text('Trip groups won\'t be able to send you the photos you\'re in until you add it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await c.clearProfile();
  }

  Future<void> _rename() async {
    final text = TextEditingController(text: _name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name on other phones'),
        content: TextField(
          controller: text,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'e.g. Maya\'s Pixel'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await ShareIdentity.setAlias(c.db, name);
    if (!mounted) return;
    setState(() => _name = name.trim());
    _toast('Saved. Other phones see the new name after the app restarts.');
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Aurora(
      intensity: 0.7,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final p = c.profile;
            final n = p.faces.length;
            final fromPeople = p.source == FaceSource.people;
            final title = !p.isSet
                ? 'Add your face'
                : n >= FaceProfile.enough || fromPeople
                    ? 'Your face is set'
                    : 'Add ${FaceProfile.enough - n} more';
            final sub = !p.isSet
                ? 'So friends\' phones know which photos are yours'
                : fromPeople
                    ? 'From your photos in People'
                    : n < FaceProfile.enough
                        ? 'More photos of you match better'
                        : 'From $n ${p.source == FaceSource.upload ? 'photos' : 'selfies and photos'}';
            return GlassScrollView(
              title: 'Profile',
              subtitle: 'Who you are to other phones',
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.paddingOf(context).bottom + 32),
                  sliver: SliverList.list(children: [
                    SectionCard(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                      child: Column(children: [
                        _FaceRing(
                          thumb: p.thumb,
                          filled: fromPeople ? 1 : (n / FaceProfile.enough).clamp(0.0, 1.0),
                          busy: _busy,
                          name: _name,
                        ),
                        const SizedBox(height: 16),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Column(key: ValueKey(title), children: [
                            Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                            const SizedBox(height: 4),
                            Text(sub,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                          ]),
                        ),
                        const SizedBox(height: 20),
                        if (_hasCamera) ...[
                          FilledButton.icon(
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                            onPressed: _busy ? null : _selfie,
                            icon: const Icon(Icons.photo_camera_front_rounded),
                            label: Text(p.isSet ? 'Take another selfie' : 'Take a selfie'),
                          ),
                          const SizedBox(height: 10),
                        ],
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                          onPressed: _busy ? null : _upload,
                          icon: const Icon(Icons.add_photo_alternate_rounded),
                          label: const Text('Upload photos of me'),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    SectionCard.rows(rows: [
                      SectionRow(
                        leading: const IconTile(icon: Icons.person_search_rounded, color: Color(0xFFFF9F0A)),
                        title: 'Use my face from People',
                        subtitle: 'Most accurate: built from many photos of you',
                        chevron: true,
                        enabled: !_busy,
                        onTap: _fromPeople,
                      ),
                      SectionRow(
                        leading: const IconTile(icon: Icons.badge_rounded, color: Color(0xFF5E5CE6)),
                        title: 'Name',
                        subtitle: _name,
                        chevron: true,
                        onTap: _rename,
                      ),
                    ]),
                    const SectionHeader(title: 'Used for'),
                    SectionCard.rows(rows: const [
                      SectionRow(
                        leading: IconTile(icon: Icons.diversity_3_rounded, color: Color(0xFF30D158)),
                        title: 'Trip groups',
                        subtitle: 'Friends\' phones send you the photos you\'re in',
                      ),
                    ]),
                    if (p.isSet) ...[
                      const SizedBox(height: 12),
                      SectionCard(
                        child: SectionRow(
                          leading: const IconTile(icon: Icons.delete_rounded, color: Color(0xFFFF453A)),
                          title: 'Remove my face',
                          destructive: true,
                          onTap: _remove,
                        ),
                      ),
                    ],
                    const SectionFooter(
                      'Your photos and selfies never leave this phone. Only a face fingerprint (a list of numbers) and '
                      'a small crop for your picture are shared, and only with groups you join.',
                    ),
                  ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Your face in a circle of ticks that light up as photos are added, like
/// setting up face unlock.
class _FaceRing extends StatelessWidget {
  const _FaceRing({required this.thumb, required this.filled, required this.busy, required this.name});

  final Uint8List? thumb;
  final double filled;
  final bool busy;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = thumb;
    return SizedBox.square(
      dimension: 196,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: filled),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => CustomPaint(
          painter: _TicksPainter(t, scheme.primary, scheme.onSurface.withValues(alpha: 0.16)),
          child: child,
        ),
        child: Center(
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 144,
              height: 144,
              decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
              clipBehavior: Clip.antiAlias,
              child: img == null
                  ? Icon(Icons.face_rounded, size: 72, color: scheme.onSurfaceVariant)
                  : Image.memory(img, fit: BoxFit.cover, gaplessPlayback: true),
            ),
            if (busy)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.45)),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
            if (filled >= 1 && !busy)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                    border: Border.all(color: Theme.of(context).scaffoldBackgroundColor, width: 3),
                  ),
                  child: Icon(Icons.check_rounded, size: 20, color: scheme.onPrimary),
                ).animate().scale(curve: Curves.easeOutBack, duration: 400.ms),
              ),
          ]),
        ),
      ),
    );
  }
}

class _TicksPainter extends CustomPainter {
  _TicksPainter(this.t, this.on, this.off);

  final double t;
  final Color on, off;
  static const _n = 72;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final paint = Paint()
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < _n; i++) {
      final a = i / _n * math.pi * 2 - math.pi / 2;
      final d = Offset(math.cos(a), math.sin(a));
      paint.color = i < (t * _n).round() ? on : off;
      canvas.drawLine(c + d * (r - 14), c + d * (r - 2), paint);
    }
  }

  @override
  bool shouldRepaint(_TicksPainter old) => old.t != t || old.on != on;
}
