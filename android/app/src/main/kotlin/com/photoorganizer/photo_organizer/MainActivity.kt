package com.photoorganizer.photo_organizer

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FragmentActivity is required by local_auth (app lock).
class MainActivity : FlutterFragmentActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var trash: TrashChannel? = null
    private var notify: NotifyChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        trash = TrashChannel(this, messenger)
        notify = NotifyChannel(applicationContext, messenger)

        // Android drops Wi-Fi multicast packets unless an app holds this lock;
        // LocalSend-style device discovery needs it while sharing is open.
        MethodChannel(messenger, "photo_organizer/multicast").setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (multicastLock == null) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("photo_organizer_share").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(true)
                }
                "release" -> {
                    multicastLock?.let { if (it.isHeld) it.release() }
                    multicastLock = null
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Received files that aren't photos go to Download/ShareBro, where
        // every Files app can see them; and they can be opened from history.
        MethodChannel(messenger, "photo_organizer/files").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")!!
                        val name = call.argument<String>("name")!!
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        val dir = call.argument<String>("dir")
                        result.success(saveToDownloads(File(path), name, mime, dir))
                    }
                    "open" -> {
                        val target = call.argument<String>("uri")!!
                        val mime = call.argument<String>("mime")
                        val uri = if (target.startsWith("/")) {
                            FileProvider.getUriForFile(this, "$packageName.files", File(target))
                        } else {
                            Uri.parse(target)
                        }
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime ?: contentResolver.getType(uri) ?: "*/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(Intent.createChooser(intent, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("files", e.message, null)
            }
        }
    }

    /** Copies [file] into Download/ShareBro[/dir] and returns its content:// URI. */
    private fun saveToDownloads(file: File, name: String, mime: String, dir: String?): String {
        val sub = if (dir.isNullOrBlank()) "ShareBro" else "ShareBro/" + dir.trim('/')
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + sub)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Couldn't create the file in Downloads")
            resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        // Android 9: plain file in the public Downloads folder.
        @Suppress("DEPRECATION")
        val folder = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), sub)
        folder.mkdirs()
        var out = File(folder, name)
        var n = 2
        val ext = MimeTypeMap.getFileExtensionFromUrl(name)
        while (out.exists()) {
            out = File(folder, name.removeSuffix(".$ext") + " ($n)" + if (ext.isNullOrEmpty()) "" else ".$ext")
            n++
        }
        file.copyTo(out)
        return out.absolutePath
    }

    @Deprecated("Android's restore/delete prompts still report here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (trash?.onActivityResult(requestCode, resultCode) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        notify?.dispose()
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
