package com.netguard.netguard_flutter

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.netguard.flutter/apps"
        private const val METHOD_GET_INSTALLED_APPS = "getInstalledApps"
        private const val ICON_SIZE_PX = 96
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_GET_INSTALLED_APPS -> fetchInstalledAppsAsync(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun fetchInstalledAppsAsync(result: MethodChannel.Result) {
        if (executor.isShutdown) {
            result.error("EXECUTOR_SHUTDOWN", "Background executor is shut down.", null)
            return
        }

        executor.execute {
            try {
                val apps = loadInstalledApps()
                mainHandler.post { result.success(apps) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "APP_FETCH_ERROR",
                        e.localizedMessage ?: "Failed to retrieve installed applications.",
                        null,
                    )
                }
            }
        }
    }

    private fun loadInstalledApps(): List<Map<String, Any>> {
        val pm = applicationContext.packageManager
        val ownPackageName = applicationContext.packageName

        val installedApplications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0L))
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledApplications(0)
        }

        val apps = ArrayList<Map<String, Any>>(installedApplications.size)
        for (appInfo in installedApplications) {
            if (appInfo.packageName == ownPackageName) {
                continue
            }

            val rawLabel = pm.getApplicationLabel(appInfo).toString().trim()
            val appName = rawLabel.ifEmpty { appInfo.packageName }
            val isSystemApp = (appInfo.flags and
                (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
            val iconBytes = loadResizedIconBytes(pm, appInfo)

            apps.add(
                mapOf(
                    "appName" to appName,
                    "packageName" to appInfo.packageName,
                    "isSystemApp" to isSystemApp,
                    "icon" to iconBytes,
                ),
            )
        }

        apps.sortBy { (it["appName"] as String).lowercase() }
        return apps
    }

    private fun loadResizedIconBytes(
        pm: PackageManager,
        appInfo: ApplicationInfo,
    ): ByteArray {
        return try {
            val drawable = appInfo.loadIcon(pm)
            drawableToPngBytes(drawable, ICON_SIZE_PX)
        } catch (_: Exception) {
            ByteArray(0)
        }
    }

    private fun drawableToPngBytes(drawable: Drawable, sizePx: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        return try {
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            ByteArrayOutputStream().use { outputStream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, outputStream)
                outputStream.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }
}
