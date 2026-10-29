import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something in the phone's trash (Android 11+), kept for 30 days.
class TrashItem {
  TrashItem({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.isVideo,
    required this.expires,
    required this.duration,
  });

  factory TrashItem.fromMap(Map<Object?, Object?> m) => TrashItem(
        id: (m['id']! as num).toInt(),
        name: m['name'] as String? ?? 'Item',
        mime: m['mime'] as String? ?? '',
        size: (m['size'] as num?)?.toInt() ?? 0,
        isVideo: m['video'] == true,
        expires: DateTime.fromMillisecondsSinceEpoch((m['expires'] as num?)?.toInt() ?? 0),
        duration: Duration(milliseconds: (m['duration'] as num?)?.toInt() ?? 0),
      );

  final int id;
  final String name;
  final String mime;
  final int size;
  final bool isVideo;

  /// When Android deletes it for good.
  final DateTime expires;
  final Duration duration;

  int get daysLeft => expires.difference(DateTime.now()).inHours <= 0
      ? 0
      : (expires.difference(DateTime.now()).inHours / 24).ceil();
}

/// The phone's trash: list, thumbnails, restore and delete forever. Android
/// shows its own confirmation for restoring and deleting.
class Trash {
  static const _channel = MethodChannel('photo_organizer/trash');

  /// Bumped when items are restored or deleted, so screens refresh.
  static final changed = ValueNotifier<int>(0);

  static bool? _available;

  /// False before Android 11, which has no trash.
  static Future<bool> available() async {
    if (_available != null) return _available!;
    try {
      _available = await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      _available = false;
    }
    return _available!;
  }

  static Future<List<TrashItem>> list() async {
    if (!await available()) return const [];
    final rows = await _channel.invokeListMethod<Map<Object?, Object?>>('list') ?? const [];
    return [for (final r in rows) TrashItem.fromMap(r)];
  }

  static final _thumbs = <(int, int), Future<Uint8List?>>{};

  /// A JPEG thumbnail about [size] px (cached).
  static Future<Uint8List?> thumbnail(TrashItem item, {int size = 300}) =>
      _thumbs.putIfAbsent((item.id, size), () async {
        try {
          return await _channel.invokeMethod<Uint8List>('thumb', {'id': item.id, 'video': item.isVideo, 'size': size});
        } on PlatformException {
          return null;
        }
      });

  /// Puts [items] back where they were. Returns how many came back.
  static Future<int> restore(List<TrashItem> items) => _ask('restore', items);

  /// Deletes [items] for good. Returns how many were deleted.
  static Future<int> deleteForever(List<TrashItem> items) => _ask('delete', items);

  static Future<int> _ask(String method, List<TrashItem> items) async {
    if (items.isEmpty) return 0;
    final done = await _channel.invokeListMethod<Object?>(method, {
          'ids': [for (final i in items) i.id],
          'videos': [for (final i in items) i.isVideo],
        }) ??
        const [];
    if (done.isNotEmpty) {
      for (final i in items) {
        _thumbs.removeWhere((k, _) => k.$1 == i.id);
      }
      changed.value++;
    }
    return done.length;
  }
}
