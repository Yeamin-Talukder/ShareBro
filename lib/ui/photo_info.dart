import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/dates.dart';
import '../data/db.dart';
import '../scan/scan_controller.dart';
import 'person_screen.dart';
import 'widgets.dart';

/// Bottom sheet with a photo's date, size, resolution, location and the
/// people recognised in it.
Future<void> showPhotoInfo(
    BuildContext context, String assetId, ScanController controller) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => PhotoInfoPanel(assetId: assetId, controller: controller),
  );
}

class _Info {
  _Info({
    required this.asset,
    required this.title,
    required this.bytes,
    required this.location,
    required this.scanned,
    required this.people,
  });

  final AssetEntity asset;
  final String title;
  final int? bytes;
  final LatLng? location;
  final bool scanned;
  final List<PhotoPerson> people;
}

/// The photo details themselves, used in the bottom sheet and in the
/// viewer's pull-up panel ([embedded]).
class PhotoInfoPanel extends StatefulWidget {
  const PhotoInfoPanel({
    super.key,
    required this.assetId,
    required this.controller,
    this.embedded = false,
  });

  final String assetId;
  final ScanController controller;
  final bool embedded;

  @override
  State<PhotoInfoPanel> createState() => _PhotoInfoState();
}

class _PhotoInfoState extends State<PhotoInfoPanel> {
  late final Future<_Info?> _info = _load();

  Future<_Info?> _load() async {
    final asset = await AssetThumb.entity(widget.assetId);
    if (asset == null) return null;
    final db = widget.controller.db;
    final file = await asset.file;
    final ll = await asset.latlngAsync();
    return _Info(
      asset: asset,
      title: await asset.titleAsync,
      bytes: file == null ? null : await file.length(),
      // Photos without GPS report 0,0.
      location: ll == null || (ll.latitude == 0 && ll.longitude == 0) ? null : ll,
      scanned: await db.isScanned(widget.assetId),
      people: await db.peopleInPhoto(widget.assetId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder<_Info?>(
      future: _info,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
              height: 200, child: Center(child: CircularProgressIndicator()));
        }
        final info = snap.data;
        if (info == null) {
          return const SizedBox(
              height: 160, child: Center(child: Text('This photo is no longer on the phone.')));
        }
        final a = info.asset;
        final taken = a.createDateTime;
        final rows = <Widget>[
          _row(Icons.calendar_today_outlined, formatSectionDay(taken),
              formatTime(taken)),
          _row(Icons.image_outlined, info.title, [
            '${a.width} × ${a.height}',
            if (a.width > 0 && a.height > 0)
              '${(a.width * a.height / 1e6).toStringAsFixed(1)} MP',
            if (info.bytes != null) formatBytes(info.bytes!),
          ].join(' · ')),
          if (info.location != null)
            _row(
              Icons.place_outlined,
              '${info.location!.latitude.toStringAsFixed(5)}, '
                  '${info.location!.longitude.toStringAsFixed(5)}',
              'Location where it was taken',
              trailing: IconButton(
                tooltip: 'Copy coordinates',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: '${info.location!.latitude},${info.location!.longitude}'));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Coordinates copied')));
                },
              ),
            )
          else
            _row(Icons.location_off_outlined, 'No location', 'This photo has no GPS data'),
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text('Details',
                      style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                ),
                for (final (i, r) in rows.indexed)
                  r.animate().fadeIn(delay: (50 * i).ms).moveY(begin: 8),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('People in this photo',
                      style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: !info.scanned
                      ? Text('Not scanned for faces yet.', style: text.bodyMedium)
                      : info.people.isEmpty
                          ? Text('No recognised people.', style: text.bodyMedium)
                          : Wrap(spacing: 8, runSpacing: 8, children: [
                              for (final (i, p) in info.people.indexed)
                                ActionChip(
                                  avatar: CircleAvatar(
                                      backgroundImage: MemoryImage(p.thumb)),
                                  label: Text(p.displayName),
                                  onPressed: () {
                                    final nav = Navigator.of(context);
                                    if (!widget.embedded) nav.pop();
                                    nav.push(
                                      MaterialPageRoute(
                                        builder: (_) => PersonScreen(
                                            controller: widget.controller,
                                            personId: p.id),
                                      ),
                                    );
                                  },
                                )
                                    .animate()
                                    .fadeIn(delay: (200 + 60 * i).ms)
                                    .scaleXY(begin: 0.6, curve: Curves.easeOutBack),
                            ]),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(IconData icon, String title, String subtitle, {Widget? trailing}) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: trailing,
    );
  }
}
