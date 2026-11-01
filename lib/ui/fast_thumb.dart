import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
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
      if (size <= _nativeUpTo) {
        final fast = await _native(id, target, a.type == AssetType.video);
        if (fast != null) return fast;
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

  static const _channel = MethodChannel('photo_organizer/thumbs');

  /// Android's own ready-made thumbnails cover sizes up to about this;
  /// bigger ones (the viewer) come from the full photo.
  static const _nativeUpTo = 512;
  static bool _nativeWorks = Platform.isAndroid;

  /// Android's stored thumbnail of [id], about [size] px, as RGBA bytes;
  /// null when there isn't one (Android 9, or no thumbnail).
  static Future<({int width, int height, Uint8List rgba})?> pixels(String id, int size, {bool video = false}) async {
    if (!_nativeWorks) return null;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
          'thumb', {'id': id, 'width': size, 'height': size, 'video': video});
      if (r == null) return null;
      return (width: r['w']! as int, height: r['h']! as int, rgba: r['px']! as Uint8List);
    } on MissingPluginException {
      _nativeWorks = false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Android's stored thumbnail as raw pixels: no full-size decode on the
  /// phone's side and no JPEG round trip. Null when unavailable (Android 9,
  /// or a file Android has no thumbnail for).
  static Future<ui.Codec?> _native(String id, ThumbnailSize target, bool video) async {
    if (!_nativeWorks) return null;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
          'thumb', {'id': id, 'width': target.width, 'height': target.height, 'video': video});
      if (r == null) return null;
      final w = r['w']! as int, h = r['h']! as int;
      final buffer = await ui.ImmutableBuffer.fromUint8List(r['px']! as Uint8List);
      final descriptor = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
      buffer.dispose();
      return await descriptor.instantiateCodec();
    } on MissingPluginException {
      _nativeWorks = false;
      return null;
    } catch (_) {
      return null;
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
