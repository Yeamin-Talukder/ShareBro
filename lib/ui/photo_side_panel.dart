import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/dates.dart';
import '../data/db.dart';
import '../platform/device.dart';
import '../scan/scan_controller.dart';
import 'anim.dart';
import 'person_screen.dart';
import 'photo_info.dart';
import 'theme.dart';

/// The viewer is always dark, whatever the app theme, so the panel uses
/// fixed colours rather than the theme's.
const _surface = Color(0xFF121016);
const _card = Color(0xFF1C1A22);
const _ink = Color(0xFFF2EFF5);
const _dim = Color(0xA3F2EFF5); // 64%
const _faint = Color(0x6BF2EFF5); // 42%
const _line = Color(0x12FFFFFF);
const _onAccent = Color(0xFF2A0D06);
const _accent = Brand.accentDark;

/// Width of the desktop viewer's info panel.
const photoSidePanelWidth = 310.0;

/// Desktop viewer: who's in the photo, its details and actions, beside the
/// photo (the phone pulls these up from the bottom instead).
class PhotoSidePanel extends StatefulWidget {
  const PhotoSidePanel({
    super.key,
    required this.assetId,
    required this.controller,
    required this.onSend,
    required this.onShowInFolder,
    required this.onDelete,
  });

  final String assetId;
  final ScanController controller;
  final VoidCallback? onSend, onShowInFolder, onDelete;

  @override
  State<PhotoSidePanel> createState() => _PhotoSidePanelState();
}

/// One face in the photo, and how many photos its person is in.
typedef _Face = ({PhotoPerson? person, int photos});

class _PhotoSidePanelState extends State<PhotoSidePanel> {
  late Future<PhotoDetails?> _details;
  late Future<List<_Face>> _faces;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PhotoSidePanel old) {
    super.didUpdateWidget(old);
    if (old.assetId != widget.assetId) _load();
  }

  void _load() {
    _details = loadPhotoDetails(widget.assetId, widget.controller);
    _faces = _loadFaces();
  }

  /// Faces left to right, each person once; faces not grouped yet too.
  Future<List<_Face>> _loadFaces() async {
    final db = widget.controller.db;
    final found = await db.facesInPhoto(widget.assetId);
    found.sort((a, b) => a.box.left.compareTo(b.box.left));
    final seen = <int>{};
    final out = <_Face>[];
    for (final f in found) {
      final person = f.person;
      if (person != null && !seen.add(person.id)) continue;
      out.add((person: person, photos: person == null ? 0 : (await db.photosWithAll([person.id])).length));
    }
    return out;
  }

  void _openPerson(PhotoPerson person) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PersonScreen(controller: widget.controller, personId: person.id)),
      );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(left: BorderSide(color: _line)),
      ),
      child: SizedBox(
        width: photoSidePanelWidth,
        child: DefaultTextStyle(
          style: const TextStyle(color: _ink, fontSize: TextSize.caption),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
            children: [
              const _Heading('In this photo', first: true),
              FutureBuilder<List<_Face>>(
                future: _faces,
                builder: (context, snap) {
                  final faces = snap.data;
                  if (faces == null) return const SizedBox(height: 52);
                  if (faces.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Text('No faces found in this photo.', style: TextStyle(color: _dim)),
                    );
                  }
                  return Column(children: [
                    for (final (i, f) in faces.indexed)
                      _PersonRow(face: f, onOpen: f.person == null ? null : () => _openPerson(f.person!))
                          .animate()
                          .fadeIn(delay: (40 * i).ms, duration: 200.ms)
                          .moveX(begin: 8, delay: (40 * i).ms, duration: 220.ms),
                  ]);
                },
              ),
              const SizedBox(height: 10),
              _AccentButton(icon: Icons.send_rounded, label: 'Send…', onTap: widget.onSend),
              const _Heading('Details'),
              FutureBuilder<PhotoDetails?>(
                future: _details,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 160);
                  final d = snap.data;
                  if (d == null) {
                    return Text(
                      Device.desktop ? 'This photo is no longer in its folder.' : 'This photo is no longer on the phone.',
                      style: const TextStyle(color: _dim),
                    );
                  }
                  return _detailRows(d);
                },
              ),
              const _Heading('More'),
              Row(children: [
                Expanded(
                  child: _PlainButton(
                    icon: Device.desktop ? Icons.folder_open_outlined : Icons.share_outlined,
                    label: Device.desktop ? 'Show in folder' : 'Share',
                    onTap: widget.onShowInFolder,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _PlainButton(icon: Icons.delete_outline_rounded, label: 'Delete', onTap: widget.onDelete)),
              ]),
              const SizedBox(height: 16),
              const _KeyHints(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRows(PhotoDetails d) {
    final taken = d.asset.createDateTime;
    final folder = d.asset.relativePath ?? '';
    final loc = d.location;
    return Column(children: [
      _Detail(icon: Icons.calendar_today_outlined, title: formatSectionDay(taken), sub: formatTime(taken)),
      _Detail(icon: Icons.image_outlined, title: d.title, sub: d.sizeLine),
      if (folder.isNotEmpty)
        _Detail(
          icon: Icons.folder_outlined,
          title: p.basename(folder.endsWith('/') || folder.endsWith(r'\') ? folder.substring(0, folder.length - 1) : folder),
          sub: folder,
        ),
      if (loc != null)
        _Detail(
          icon: Icons.place_outlined,
          title: 'Where it was taken',
          sub: '${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)}',
          onTap: () {
            Clipboard.setData(ClipboardData(text: '${loc.latitude},${loc.longitude}'));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Coordinates copied')));
          },
          tooltip: 'Copy coordinates',
        )
      else
        const _Detail(icon: Icons.location_off_outlined, title: 'No location', sub: 'This photo has no GPS data'),
    ]);
  }
}

/// "IN THIS PHOTO", "DETAILS"…
class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.first = false});

  final String text;
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: first ? 0 : 20, bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(color: _faint, fontSize: TextSize.tiny, fontWeight: FontWeight.w600, letterSpacing: 0.9),
        ),
      );
}

/// A person in the photo: their face, name and photo count. People without
/// a name get a dashed ring and a "Name" pill; faces not grouped yet say so.
class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.face, required this.onOpen});

  final _Face face;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final person = face.person;
    final unnamed = person != null && person.name == null;
    final Widget avatar;
    if (person == null) {
      avatar = CustomPaint(
        painter: _DashedRing(color: _accent),
        child: const SizedBox.square(
          dimension: 38,
          child: Icon(Icons.person_add_alt_1_rounded, size: 20, color: _accent),
        ),
      );
    } else {
      final img = CircleAvatar(radius: 19, backgroundImage: MemoryImage(person.thumb));
      avatar = unnamed
          ? CustomPaint(
              foregroundPainter: _DashedRing(color: _accent),
              child: Padding(padding: const EdgeInsets.all(3), child: CircleAvatar(radius: 16, backgroundImage: MemoryImage(person.thumb))),
            )
          : img;
    }
    final title = person == null ? 'Not grouped yet' : (person.name ?? 'Someone new');
    final sub = person == null ? 'Rescan or review faces to group it' : '${face.photos} ${face.photos == 1 ? 'photo' : 'photos'}';
    return _Hover(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        child: Row(children: [
          SizedBox.square(dimension: 38, child: avatar),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: TextSize.label, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _faint, fontSize: TextSize.small)),
            ]),
          ),
          if (unnamed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(color: _accent.withAlpha(36), borderRadius: BorderRadius.circular(999)),
              child: const Text('Name',
                  style: TextStyle(color: _accent, fontSize: TextSize.small, fontWeight: FontWeight.w700)),
            )
          else if (person != null)
            const Icon(Icons.chevron_right_rounded, size: 20, color: _faint),
        ]),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.icon, required this.title, required this.sub, this.onTap, this.tooltip});

  final IconData icon;
  final String title, sub;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 19, color: _faint),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: TextSize.caption)),
            const SizedBox(height: 1),
            SelectableText(sub, style: const TextStyle(color: _faint, fontSize: TextSize.small)),
          ]),
        ),
        if (onTap != null) const Icon(Icons.copy_rounded, size: 16, color: _faint),
      ]),
    );
    if (onTap == null) return row;
    return Tooltip(message: tooltip ?? '', child: _Hover(onTap: onTap, child: row));
  }
}

/// The full-width coral button ("Send…").
class _AccentButton extends StatelessWidget {
  const _AccentButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onTap == null ? _accent.withAlpha(110) : _accent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 44,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 19, color: _onAccent),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: _onAccent, fontWeight: FontWeight.w700, fontSize: TextSize.label)),
          ]),
        ),
      ),
    );
  }
}

/// "Show in folder" / "Delete".
class _PlainButton extends StatelessWidget {
  const _PlainButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: _line)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: Colors.white.withAlpha(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: _dim),
            const SizedBox(width: 7),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _dim, fontSize: TextSize.small, fontWeight: FontWeight.w500)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// "← → next · F faces · I info · Esc back".
class _KeyHints extends StatelessWidget {
  const _KeyHints();

  @override
  Widget build(BuildContext context) {
    Widget key(String k) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _line),
          ),
          child: Text(k, style: const TextStyle(color: _dim, fontSize: TextSize.tiny)),
        );
    const label = TextStyle(color: _faint, fontSize: TextSize.tiny);
    return Wrap(
      spacing: 5,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        key('←'), key('→'), const Text('next  ·', style: label),
        key('F'), const Text('faces  ·', style: label),
        key('I'), const Text('info  ·', style: label),
        key('Esc'), const Text('back', style: label),
      ],
    );
  }
}

/// A row that lights up under the mouse.
class _Hover extends StatefulWidget {
  const _Hover({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _on = true),
      onExit: (_) => setState(() => _on = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: 120.ms,
          decoration: BoxDecoration(
            color: _on ? Colors.white.withAlpha(12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A dashed circle around a face that has no name yet.
class _DashedRing extends CustomPainter {
  _DashedRing({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final r = size.shortestSide / 2 - 1;
    final c = size.center(Offset.zero);
    const dashes = 14;
    const sweep = 2 * 3.141592653589793 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * sweep, sweep * 0.6, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => old.color != color;
}
