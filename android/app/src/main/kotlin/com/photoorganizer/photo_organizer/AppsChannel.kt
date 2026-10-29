package com.photoorganizer.photo_organizer

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Installed apps, for sending them like files: each app's APK (plus its
 * split APKs, for apps installed from app bundles), name, version, size and
 * icon. Only apps with a home-screen icon are listed.
 */
class AppsChannel(private val context: Context, messenger: BinaryMessenger) {
    private val io = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "photo_organizer/apps").setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> io.execute {
                    try {
                        val apps = list(call.argument<Boolean>("system") ?: false)
                        main.post { result.success(apps) }
                    } catch (e: Exception) {
                        main.post { result.error("apps", e.message, null) }
                    }
                }
                "icon" -> {
                    val pkg = call.argument<String>("package")!!
                    val size = call.argument<Int>("size") ?: 96
                    io.execute {
                        val bytes = try { icon(pkg, size) } catch (_: Exception) { null }
                        main.post { result.success(bytes) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun list(includeSystem: Boolean): List<Map<String, Any?>> {
        val pm = context.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val launchable = pm.queryIntentActivities(launcher, 0).map { it.activityInfo.packageName }.toSet()
        val out = mutableListOf<Map<String, Any?>>()
        for (pkg in launchable) {
            if (pkg == context.packageName) continue
            val info = try { pm.getPackageInfo(pkg, 0) } catch (_: PackageManager.NameNotFoundException) { continue }
            val app = info.applicationInfo ?: continue
            // Built-in apps (unless updated) can't usefully be installed elsewhere.
            val system = app.flags and ApplicationInfo.FLAG_SYSTEM != 0 &&
                app.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP == 0
            if (system && !includeSystem) continue
            val files = listOf(app.sourceDir) + (app.splitSourceDirs?.toList() ?: emptyList())
            val readable = files.filter { File(it).canRead() }
            if (readable.isEmpty()) continue
            out.add(mapOf(
                "package" to pkg,
                "name" to app.loadLabel(pm).toString(),
                "version" to (info.versionName ?: ""),
                "files" to readable,
                "size" to readable.sumOf { File(it).length() },
                "system" to system,
                "updated" to info.lastUpdateTime,
            ))
        }
        return out.sortedBy { (it["name"] as String).lowercase() }
    }

    private fun icon(pkg: String, size: Int): ByteArray? {
        val drawable = context.packageManager.getApplicationIcon(pkg)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val stream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, stream)
        bmp.recycle()
        return stream.toByteArray()
    }
}
