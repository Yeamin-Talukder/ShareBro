package com.photoorganizer.photo_organizer

import android.app.Activity
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * In-app updates: this app's version and CPU types (to pick the right APK),
 * whether the network is metered, the "Install unknown apps" permission,
 * and handing a downloaded APK to Android's package installer.
 */
class UpdateChannel(private val activity: Activity, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, "photo_organizer/update").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val pm = activity.packageManager
                        @Suppress("DEPRECATION")
                        val info = pm.getPackageInfo(activity.packageName, 0)
                        result.success(
                            mapOf(
                                "version" to (info.versionName ?: ""),
                                "abis" to Build.SUPPORTED_ABIS.toList(),
                            ),
                        )
                    }
                    "unmetered" -> result.success(unmetered())
                    "canInstall" -> result.success(canInstall())
                    "allowInstall" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            activity.startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ),
                            )
                        }
                        result.success(true)
                    }
                    "install" -> {
                        val file = File(call.argument<String>("path")!!)
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        activity.startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("update", e.message, null)
            }
        }
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    /** Wi-Fi or Ethernet, not mobile data or a metered hotspot. */
    private fun unmetered(): Boolean {
        val cm = activity.getSystemService(ConnectivityManager::class.java) ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
