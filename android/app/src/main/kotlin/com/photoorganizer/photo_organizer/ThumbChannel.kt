package com.photoorganizer.photo_organizer

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/**
 * Fast grid thumbnails (Android 10+): Android keeps a ready-made thumbnail
 * of every photo and video, so this reads that instead of decoding the full
 * photo, and hands the pixels to Flutter as they are (no JPEG to encode
 * here and decode again there). Older Android answers null and the app
 * falls back to the photo library plugin.
 */
class ThumbChannel(private val context: Context, messenger: BinaryMessenger) {
    private val io = Executors.newFixedThreadPool(6)
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "photo_organizer/thumbs").setMethodCallHandler { call, result ->
            if (call.method != "thumb") return@setMethodCallHandler result.notImplemented()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@setMethodCallHandler result.success(null)
            val id = call.argument<String>("id")!!.toLongOrNull()
                ?: return@setMethodCallHandler result.success(null)
            val width = call.argument<Int>("width")!!
            val height = call.argument<Int>("height")!!
            val video = call.argument<Boolean>("video") ?: false
            io.execute {
                val reply = try {
                    load(id, width, height, video)
                } catch (e: Exception) {
                    null
                }
                main.post { result.success(reply) }
            }
        }
    }

    private fun load(id: Long, width: Int, height: Int, video: Boolean): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val collection = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val uri = ContentUris.withAppendedId(collection, id)
        var bitmap = context.contentResolver.loadThumbnail(uri, Size(width, height), null)
        // It comes back "about" the size asked for; shrink a big one so less
        // crosses over to Flutter.
        val fit = minOf(1f, maxOf(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height) * 1.15f)
        if (fit < 0.95f) {
            val scaled = Bitmap.createScaledBitmap(
                bitmap, maxOf(1, (bitmap.width * fit).toInt()), maxOf(1, (bitmap.height * fit).toInt()), true
            )
            if (scaled != bitmap) bitmap.recycle()
            bitmap = scaled
        }
        if (bitmap.config != Bitmap.Config.ARGB_8888) {
            val copy = bitmap.copy(Bitmap.Config.ARGB_8888, false)
            bitmap.recycle()
            bitmap = copy
        }
        // ARGB_8888 sits in memory as R, G, B, A bytes: Flutter's rgba8888.
        val pixels = ByteBuffer.allocate(bitmap.byteCount)
        bitmap.copyPixelsToBuffer(pixels)
        val out = mapOf("w" to bitmap.width, "h" to bitmap.height, "px" to pixels.array())
        bitmap.recycle()
        return out
    }
}
