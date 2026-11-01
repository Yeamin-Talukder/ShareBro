package com.photoorganizer.photo_organizer

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Rich notifications for transfers and scans: progress bars, a thumbnail,
 * Accept / Decline / Cancel buttons, a photo preview when done, and on
 * Android 16+ a "Live Update" (the progress chip in the status bar).
 * Buttons come back to Dart as "action" calls.
 */
class NotifyChannel(private val context: Context, messenger: BinaryMessenger) {
    companion object {
        const val REQUESTS = "requests"
        const val PROGRESS = "progress"
        const val DONE = "done"
        const val SCAN = "scan_progress"
        const val EXTRA_ID = "notify_id"
        const val EXTRA_ACTION = "notify_action"

        /** Which screen a tap on the notification should open. */
        const val EXTRA_OPEN = "notify_open"
        const val ACTION_TAP = "photo_organizer.NOTIFY_ACTION"

        /** The live channel, while the app is running. */
        var instance: NotifyChannel? = null
    }

    private val channel = MethodChannel(messenger, "photo_organizer/notify")
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val accent = Color.rgb(0xFF, 0x8A, 0x6B)

    init {
        instance = this
        createChannels()
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
                        show(
                            id = call.argument<Int>("id")!!,
                            kind = call.argument<String>("kind")!!,
                            title = call.argument<String>("title")!!,
                            text = call.argument<String>("text") ?: "",
                            sub = call.argument<String>("sub"),
                            progress = call.argument<Double>("progress"),
                            chip = call.argument<String>("chip"),
                            thumb = call.argument<ByteArray>("thumb"),
                            picture = call.argument<ByteArray>("picture"),
                            actions = call.argument<List<Map<String, String>>>("actions") ?: emptyList(),
                            open = call.argument<String>("open"),
                            group = call.argument<String>("group"),
                            lines = call.argument<List<String>>("lines"),
                            segments = call.argument<Int>("segments"),
                        )
                        result.success(true)
                    }
                    // A tap that launched the app before Dart was listening.
                    "takeOpen" -> {
                        result.success(pendingOpen)
                        pendingOpen = null
                    }
                    "cancel" -> {
                        manager.cancel(call.argument<Int>("id")!!)
                        result.success(true)
                    }
                    "canPost" -> result.success(canPost())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("notify", e.message, null)
            }
        }
    }

    fun dispose() {
        if (instance === this) instance = null
    }

    /** Screen a notification tap asked for, until Dart picks it up. */
    private var pendingOpen: String? = null

    /** A notification was tapped: open [target] in the app. */
    fun onOpen(target: String) {
        pendingOpen = target
        main.post { channel.invokeMethod("open", target, object : MethodChannel.Result {
            override fun success(result: Any?) { pendingOpen = null }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        }) }
    }

    /** A button was pressed (from the receiver). */
    fun onAction(id: Int, action: String) {
        main.post { channel.invokeMethod("action", mapOf("id" to id, "action" to action)) }
    }

    private fun canPost(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        fun ch(id: String, name: String, desc: String, importance: Int) =
            NotificationChannel(id, name, importance).apply {
                description = desc
                setShowBadge(importance >= NotificationManager.IMPORTANCE_DEFAULT)
            }
        manager.createNotificationChannels(listOf(
            ch(REQUESTS, "Incoming files", "Someone wants to send you photos or files", NotificationManager.IMPORTANCE_HIGH),
            ch(PROGRESS, "Transfer progress", "Live progress while sending and receiving", NotificationManager.IMPORTANCE_LOW),
            ch(DONE, "Finished transfers", "When a send or receive is done", NotificationManager.IMPORTANCE_DEFAULT),
            ch(SCAN, "Face scanning", "Progress while photos are scanned for faces", NotificationManager.IMPORTANCE_LOW),
        ))
    }

    private fun openApp(id: Int, open: String?): PendingIntent {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        open?.let { intent.putExtra(EXTRA_OPEN, it) }
        return PendingIntent.getActivity(context, id, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun actionIntent(id: Int, action: String): PendingIntent {
        val intent = Intent(context, NotifyReceiver::class.java)
            .setAction(ACTION_TAP)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_ACTION, action)
        return PendingIntent.getBroadcast(
            context, (id * 31 + action.hashCode()), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun bitmap(bytes: ByteArray?): Bitmap? =
        bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }

    @SuppressLint("MissingPermission")
    private fun show(
        id: Int,
        kind: String,
        title: String,
        text: String,
        sub: String?,
        progress: Double?,
        chip: String?,
        thumb: ByteArray?,
        picture: ByteArray?,
        actions: List<Map<String, String>>,
        open: String? = null,
        group: String? = null,
        lines: List<String>? = null,
        segments: Int? = null,
    ) {
        if (!canPost()) return
        val channelId = when (kind) {
            "request" -> REQUESTS
            "progress" -> PROGRESS
            "scan" -> SCAN
            else -> DONE
        }
        val summary = kind == "summary"
        val ongoing = kind == "progress" || kind == "scan"
        val b = Notification.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notify)
            .setColor(accent)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openApp(id, open))
            .setOnlyAlertOnce(ongoing)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setShowWhen(!ongoing)
            .setCategory(
                when (kind) {
                    "request" -> Notification.CATEGORY_MESSAGE
                    "progress", "scan" -> Notification.CATEGORY_PROGRESS
                    else -> Notification.CATEGORY_STATUS
                },
            )
        sub?.let { b.setSubText(it) }
        // Finished transfers stack under one summary.
        group?.let { b.setGroup(it).setGroupSummary(summary) }
        if (summary && lines != null) {
            b.setStyle(Notification.InboxStyle().also { s -> lines.forEach { s.addLine(it) } }.setSummaryText(text))
        }
        bitmap(thumb)?.let { b.setLargeIcon(it) }
        for (a in actions) {
            val action = a["id"]!!
            // "open:review" etc. open the app at that screen; the rest are
            // handled in the background (Accept, Cancel, Retry…).
            val intent = if (action.startsWith("open:")) openApp(id * 31 + action.hashCode(), action.removePrefix("open:"))
            else actionIntent(id, action)
            b.addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, a["label"], intent).build())
        }

        val p = progress
        if (ongoing && Build.VERSION.SDK_INT >= 36) {
            // Android 16 Live Update: a progress-centric notification that
            // also shows as a chip in the status bar.
            val style = Notification.ProgressStyle()
                .setStyledByProgress(true)
                // One segment per file (a dozen at most), like the demo.
                .setProgressSegments(
                    List((segments ?: 1).coerceIn(1, 12)) { Notification.ProgressStyle.Segment(1000).setColor(accent) },
                )
            val total = 1000 * (segments ?: 1).coerceIn(1, 12)
            if (p == null || p < 0) style.setProgressIndeterminate(true) else style.setProgress((p * total).toInt())
            b.setStyle(style)
            // Ask for promotion to a Live Update (Notification.EXTRA_REQUEST_PROMOTED_ONGOING).
            b.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
            chip?.let { b.setShortCriticalText(it) }
        } else if (ongoing) {
            if (p == null || p < 0) b.setProgress(0, 0, true) else b.setProgress(1000, (p * 1000).toInt(), false)
        } else if (summary) {
            // Style set above.
        } else if (picture != null) {
            bitmap(picture)?.let { pic ->
                b.setStyle(Notification.BigPictureStyle().bigPicture(pic).setSummaryText(text))
            }
        } else if (text.length > 40) {
            b.setStyle(Notification.BigTextStyle().bigText(text))
        }
        manager.notify(id, b.build())
    }
}

/** Notification buttons land here and go on to Dart. */
class NotifyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(NotifyChannel.EXTRA_ID, 0)
        val action = intent.getStringExtra(NotifyChannel.EXTRA_ACTION) ?: return
        val live = NotifyChannel.instance
        if (live != null) {
            live.onAction(id, action)
        } else {
            // The app isn't running any more: open it instead.
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ?.let(context::startActivity)
        }
    }
}
