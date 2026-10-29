import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:photo_manager/photo_manager.dart';

import 'widgets.dart' show AssetThumb;

/// Thumbnails straight from the photo library, made for speed: keyed by
/// asset id (so every screen shares the same cached copy), sized in a few
/// fixed steps (so a grid and the viewer reuse each other's images), and
/// encoded at a lighter JPEG quality than the default 95.
@immutable
class FastThumb extends ImageProvider<FastThumb> {
  /// The whole photo, [size] px on its long side — or, with [cover], on its
  /// short side, so it stays sharp when cropped into a square tile.
  const FastThumb(this.id, this.size, {this.quality = 80, this.cover = false});

  final String id;
  final int size;
  final int quality;
  final bool cover;

  static const _steps = [128, 256, 384, 512, 768, 1024, 1600, 2400];

  /// The size step that covers [px] physical pixels.
  static int step(double px) => _steps.firstWhere((s) => s >= px, orElse: () => _steps.last);

  /// The step the gallery grid is showing right now, so the viewer can
  /// put the already-loaded grid thumbnail up instantly.
  static int gridStep = 384;

  @override
  Future<FastThumb> obtainKey(ImageConfiguration configuration) => SynchronousFuture<FastThumb>(this);

  @override
  ImageStreamCompleter loadImage(FastThumb key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: 'thumb-$id-$size');

  Future<ui.Codec> _load(FastThumb key, ImageDecoderCallback decode) async {
    try {
      final a = await AssetThumb.entity(id);
      if (a == null) throw StateError('Photo $id is gone');
      final w = a.orientatedWidth, h = a.orientatedHeight;
      // Keep the photo's shape (and never ask for more pixels than it has).
      final ThumbnailSize target;
      if (w <= 0 || h <= 0) {
        target = ThumbnailSize.square(size);
      } else {
        final side = cover ? (w < h ? w : h) : (w > h ? w : h);
        final scale = (size / side).clamp(0.0, 1.0);
        target = ThumbnailSize((w * scale).round().clamp(1, 1 << 14), (h * scale).round().clamp(1, 1 << 14));
      }
      final bytes = await a.thumbnailDataWithSize(target, quality: quality);
      if (bytes == null) throw StateError('No thumbnail for $id');
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // Don't keep a failed load around in the cache.
      Future<void>.microtask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FastThumb && other.id == id && other.size == size && other.quality == quality && other.cover == cover;

  @override
  int get hashCode => Object.hash(id, size, quality, cover);
}

/// Room for a few thousand thumbnails, so scrolling back up never reloads
/// (Flutter's default holds only about 100 MB).
void tuneImageCache() {
  PaintingBinding.instance.imageCache
    ..maximumSize = 4000
    ..maximumSizeBytes = 400 << 20;
}
