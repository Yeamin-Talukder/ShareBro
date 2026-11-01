import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../scan/scan_controller.dart';
import '../share/prepare.dart';
import '../share/protocol.dart';
import 'devices.dart';
import 'file_icons.dart';
import 'motion.dart';
import 'sections.dart';
import 'transfer_view.dart';
import 'web_share_screen.dart';
import 'widgets.dart';

/// "Send 12 items": nearby devices (LocalSend / Nearby), a QR link for any
/// browser, or Android's share sheet. Works for photos, files and messages.
Future<void> showSendToSheet(
  BuildContext context, {
  required ScanController controller,
  required List<SendItem> items,
  String? title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _SendToSheet(controller: controller, items: items, title: title),
  );
}

/// "3 photos", "a message", "5 files".
String describeItems(List<SendItem> items) {
  final n = items.length;
  if (items.every((i) => i.text != null)) return n == 1 ? 'a message' : '$n messages';
  if (items.every((i) => i.isAsset)) return '$n ${n == 1 ? 'item' : 'items'}';
  return '$n ${n == 1 ? 'file' : 'files'}';
}

/// Sends [items] to [t] and, with [open], opens the Sending screen.
Future<void> sendItemsTo(
  BuildContext context,
  ScanController controller,
  Target t,
  List<SendItem> items, {
  SendQuality? quality,
  bool popFirst = false,
  bool open = true,
}) async {
  final s = controller.sharing;
  Haptics.success();
  final label = describeItems(items);
  final job = t.nearbyName != null
      ? await s.enqueueNearby(personName: label, items: items, name: t.nearbyName!, quality: quality)
      : await s.enqueue(personName: label, items: items, device: t.device!, quality: quality);
  if (!context.mounted || !open) return;
  final nav = Navigator.of(context);
  if (popFirst) nav.pop();
  await nav.push(MaterialPageRoute(builder: (_) => TransferScreen(controller: controller, job: job)));
}

/// Android's share sheet for any items (messages are shared as text).
Future<void> shareItemsWithApps(List<SendItem> items) async {
  final files = <XFile>[];
  final texts = <String>[];
  for (final i in items) {
    if (i.text != null) {
      texts.add(i.text!);
    } else if (i.path != null) {
      files.add(XFile(i.path!, mimeType: mimeFor(i.path!)));
    } else if (i.assetId != null) {
      final f = await (await AssetThumb.entity(i.assetId!))?.file;
      if (f != null) files.add(XFile(f.path));
    }
  }
  await SharePlus.instance.share(ShareParams(
    files: files.isEmpty ? null : files,
    text: texts.isEmpty ? null : texts.join('\n\n'),
  ));
}

class _SendToSheet extends StatefulWidget {
  const _SendToSheet({required this.controller, required this.items, this.title});

  final ScanController controller;
  final List<SendItem> items;
  final String? title;

  @override
  State<_SendToSheet> createState() => _SendToSheetState();
}

class _SendToSheetState extends State<_SendToSheet> {
  late SendQuality _quality = widget.controller.sharing.defaultQuality;

  bool get _hasPhotos => widget.items.any((i) => i.isAsset);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final items = widget.items;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
        Text(widget.title ?? 'Send ${describeItems(items)}', style: text.headlineSmall),
        const SizedBox(height: 12),
        ItemStrip(items: items),
        if (_hasPhotos) ...[
          const SizedBox(height: 14),
          SegmentedButton<SendQuality>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: SendQuality.original, label: Text('Original')),
              ButtonSegment(value: SendQuality.noLocation, label: Text('No location')),
              ButtonSegment(value: SendQuality.smaller, label: Text('Smaller')),
            ],
            selected: {_quality},
            onSelectionChanged: (v) => setState(() => _quality = v.first),
          ),
        ],
        const SizedBox(height: 16),
        DevicePicker(
          sharing: widget.controller.sharing,
          count: items.length,
          onPick: (t) => sendItemsTo(context, widget.controller, t, items, quality: _quality, popFirst: true),
        ),
        const SizedBox(height: 22),
        SectionCard.rows(rows: [
          SectionRow(
            leading: const IconTile(icon: Icons.qr_code_2_rounded, color: Color(0xFF5E5CE6)),
            title: 'Link or QR code',
            subtitle: 'Opens in any browser',
            chevron: true,
            onTap: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute(
                builder: (_) => WebShareScreen(
                  controller: widget.controller,
                  title: widget.title ?? 'Shared with ShareBro',
                  items: items,
                  quality: _quality,
                ),
              ));
            },
          ),
          SectionRow(
            leading: const IconTile(icon: Icons.ios_share_rounded, color: Color(0xFF0A84FF)),
            title: 'Other apps',
            subtitle: 'Quick Share, WhatsApp and more',
            chevron: true,
            onTap: () {
              Navigator.pop(context);
              shareItemsWithApps(items);
            },
          ),
        ]),
      ]),
    );
  }
}

/// A horizontal strip of what's being sent: thumbnails, file badges and
/// message bubbles. With [onRemove], each one gets an ✕.
class ItemStrip extends StatelessWidget {
  const ItemStrip({super.key, required this.items, this.onRemove, this.height = 84});

  final List<SendItem> items;
  final ValueChanged<SendItem>? onRemove;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = items[i];
          final Widget body;
          if (item.assetId != null) {
            body = AssetThumb(id: item.assetId!, size: 200);
          } else if (item.text != null) {
            body = ColoredBox(
              color: scheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(item.text!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.onSecondaryContainer)),
              ),
            );
          } else {
            final name = item.name ?? p.basename(item.path!);
            body = ColoredBox(
              color: scheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  FileBadge(mime: mimeFor(name), name: name, size: 34),
                  const SizedBox(height: 4),
                  Text(p.basename(name),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10)),
                ]),
              ),
            );
          }
          return SizedBox.square(
            dimension: height,
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(borderRadius: BorderRadius.circular(12), child: body),
              if (onRemove != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () {
                      Haptics.remove();
                      onRemove!(item);
                    },
                    child: const CircleAvatar(
                      radius: 10,
                      backgroundColor: Color(0xB33C3C43),
                      child: Icon(Icons.close_rounded, size: 13, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ).animate().fadeIn(delay: (30 * i.clamp(0, 10)).ms).scaleXY(begin: 0.85, curve: Curves.easeOutBack);
        },
      ),
    );
  }
}
