package com.photoorganizer.photo_organizer

import android.app.Activity
import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The phone's trash (Android 11+): photos and videos moved there stay for
 * 30 days. Normal MediaStore queries hide them, so this asks for trashed
 * items explicitly, makes thumbnails, and restores or deletes them for good
 * (Android asks the user to confirm either).
 */
class TrashChannel(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        const val REQUEST_RESTORE = 7101
        const val REQUEST_DELETE = 7102
    }

    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingIds: List<Long> = emptyList()

    init {
        MethodChannel(messenger, "photo_organizer/trash").setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                if (call.method == "available") result.success(false) else result.error("trash", "Needs Android 11", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "available" -> result.success(true)
                "list" -> io.execute {
                    try {
                        val items = list()
                        main.post { result.success(items) }
                    } catch (e: Exception) {
                        main.post { result.error("trash", e.message, null) }
                    }
                }
                "thumb" -> {
                    val id = (call.argument<Number>("id"))!!.toLong()
                    val video = call.argument<Boolean>("video") ?: false
                    val size = call.argument<Int>("size") ?: 300
                    io.execute {
                        val bytes = try { thumb(id, video, size) } catch (_: Exception) { null }
                        main.post { result.success(bytes) }
                    }
                }
                "restore", "delete" -> {
                    val ids = call.argument<List<Number>>("ids")!!.map { it.toLong() }
                    val videos = call.argument<List<Boolean>>("videos")!!
                    ask(call.method == "restore", ids, videos, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun uriFor(id: Long, video: Boolean): Uri = ContentUris.withAppendedId(
        if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL),
        id,
    )

    @RequiresApi(Build.VERSION_CODES.R)
    private fun list(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DATE_EXPIRES,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Video.VideoColumns.DURATION,
        )
        val args = Bundle().apply {
            putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStore.MATCH_ONLY)
            putString(
                android.content.ContentResolver.QUERY_ARG_SQL_SELECTION,
                "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)",
            )
            putStringArray(
                android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS,
                arrayOf(
                    MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
                ),
            )
            putString(
                android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                "${MediaStore.Files.FileColumns.DATE_EXPIRES} ASC",
            )
        }
        activity.contentResolver.query(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), projection, args, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val video = c.getInt(4) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                out.add(mapOf(
                    "id" to c.getLong(0),
                    "name" to c.getString(1),
                    "mime" to c.getString(2),
                    "size" to c.getLong(3),
                    "video" to video,
                    "expires" to c.getLong(5) * 1000,
                    "modified" to c.getLong(6) * 1000,
                    "width" to c.getInt(7),
                    "height" to c.getInt(8),
                    "duration" to if (video) c.getLong(9) else 0L,
                ))
            }
        }
        return out
    }

    private fun thumb(id: Long, video: Boolean, size: Int): ByteArray? {
        val bmp = activity.contentResolver.loadThumbnail(uriFor(id, video), Size(size, size), null)
        val stream = ByteArrayOutputStream()
        bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, stream)
        bmp.recycle()
        return stream.toByteArray()
    }

    /** Android's own "Restore 3 items?" / "Delete 3 items forever?" prompt. */
    @RequiresApi(Build.VERSION_CODES.R)
    private fun ask(restore: Boolean, ids: List<Long>, videos: List<Boolean>, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("trash", "Another request is open", null)
            return
        }
        try {
            val uris = ids.mapIndexed { i, id -> uriFor(id, videos.getOrElse(i) { false }) }
            val request = if (restore) {
                MediaStore.createTrashRequest(activity.contentResolver, uris, false)
            } else {
                MediaStore.createDeleteRequest(activity.contentResolver, uris)
            }
            pending = result
            pendingIds = ids
            activity.startIntentSenderForResult(
                request.intentSender, if (restore) REQUEST_RESTORE else REQUEST_DELETE, null, 0, 0, 0,
            )
        } catch (e: Exception) {
            pending = null
            result.error("trash", e.message, null)
        }
    }

    /** Called from the activity; true if it was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_RESTORE && requestCode != REQUEST_DELETE) return false
        val result = pending ?: return true
        pending = null
        result.success(if (resultCode == Activity.RESULT_OK) pendingIds else emptyList<Long>())
        return true
    }
}
