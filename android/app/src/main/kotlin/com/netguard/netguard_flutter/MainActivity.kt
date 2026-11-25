package com.netguard.netguard_flutter

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val APPS_CHANNEL = "com.netguard.flutter/apps"
        private const val VPN_CHANNEL = "com.netguard.flutter/vpn"
        private const val VPN_STATUS_CHANNEL = "com.netguard.flutter/vpn_status"

        private const val METHOD_GET_INSTALLED_APPS = "getInstalledApps"
        private const val METHOD_START_FIREWALL = "startFirewall"
        private const val METHOD_STOP_FIREWALL = "stopFirewall"
        private const val METHOD_UPDATE_RULES = "updateRules"
        private const val METHOD_GET_STATUS = "getStatus"

        private const val REQUEST_CODE_VPN = 1001
        private const val REQUEST_CODE_NOTIFICATIONS = 1002
        private const val ICON_SIZE_PX = 96
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingWifiPackages: ArrayList<String> = arrayListOf()
    private var pendingMobilePackages: ArrayList<String> = arrayListOf()
    private var hasRequestedNotificationPermission = false
    private var vpnStatusEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APPS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_GET_INSTALLED_APPS -> fetchInstalledAppsAsync(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VPN_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                METHOD_START_FIREWALL -> handleStartFirewall(call, result)
                METHOD_STOP_FIREWALL -> handleStopFirewall(result)
                METHOD_UPDATE_RULES -> handleUpdateRules(call, result)
                METHOD_GET_STATUS -> result.success(buildStatusMap())
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VPN_STATUS_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    vpnStatusEventSink = events
                    FirewallVpnService.setStatusListener { isActive, networkType ->
                        vpnStatusEventSink?.success(
                            mapOf(
                                "isActive" to isActive,
                                "networkType" to networkType.wireValue,
                            ),
                        )
                    }
                    vpnStatusEventSink?.success(buildStatusMap())
                }

                override fun onCancel(arguments: Any?) {
                    vpnStatusEventSink = null
                    FirewallVpnService.setStatusListener(null)
                }
            },
        )
    }

    private fun buildStatusMap(): Map<String, Any> {
        val isActive = FirewallVpnService.isRunning
        val networkType = if (isActive) {
            FirewallVpnService.activeNetworkType
        } else {
            FirewallVpnService.detectCurrentNetworkType(this)
        }
        return mapOf(
            "isActive" to isActive,
            "networkType" to networkType.wireValue,
        )
    }

    private fun handleStartFirewall(call: MethodCall, result: MethodChannel.Result) {
        if (pendingVpnResult != null) {
            result.error("VPN_REQUEST_IN_PROGRESS", "A VPN permission request is already active.", null)
            return
        }

        val wifiList = extractStringList(call.argument<List<*>>("allowedWifiPackages"))
        val mobileList = extractStringList(call.argument<List<*>>("allowedMobilePackages"))

        pendingVpnResult = result
        pendingWifiPackages = wifiList
        pendingMobilePackages = mobileList

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasRequestedNotificationPermission &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            hasRequestedNotificationPermission = true
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_CODE_NOTIFICATIONS,
            )
            return
        }

        prepareAndStartVpn()
    }

    private fun prepareAndStartVpn() {
        val prepareIntent = VpnService.prepare(this)
        if (prepareIntent != null) {
            @Suppress("DEPRECATION")
            startActivityForResult(prepareIntent, REQUEST_CODE_VPN)
            return
        }

        startFirewallServiceAndComplete()
    }

    private fun startFirewallServiceAndComplete() {
        val result = pendingVpnResult
        val wifiList = ArrayList(pendingWifiPackages)
        val mobileList = ArrayList(pendingMobilePackages)
        clearPendingVpnRequest()

        try {
            val intent = Intent(this, FirewallVpnService::class.java).apply {
                action = FirewallVpnService.ACTION_START
                putStringArrayListExtra(FirewallVpnService.EXTRA_ALLOWED_WIFI, wifiList)
                putStringArrayListExtra(FirewallVpnService.EXTRA_ALLOWED_MOBILE, mobileList)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            result?.success(true)
        } catch (e: Exception) {
            result?.error(
                "VPN_START_FAILED",
                e.localizedMessage ?: "Failed to start firewall VPN service.",
                null,
            )
        }
    }

    private fun clearPendingVpnRequest() {
        pendingVpnResult = null
        pendingWifiPackages = arrayListOf()
        pendingMobilePackages = arrayListOf()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_NOTIFICATIONS && pendingVpnResult != null) {
            prepareAndStartVpn()
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_VPN) {
            if (resultCode == Activity.RESULT_OK) {
                startFirewallServiceAndComplete()
            } else {
                val result = pendingVpnResult
                clearPendingVpnRequest()
                result?.success(false)
            }
        }
    }

    private fun handleStopFirewall(result: MethodChannel.Result) {
        if (FirewallVpnService.isRunning) {
            val intent = Intent(this, FirewallVpnService::class.java).apply {
                action = FirewallVpnService.ACTION_STOP
            }
            startService(intent)
        }
        result.success(null)
    }

    private fun handleUpdateRules(call: MethodCall, result: MethodChannel.Result) {
        if (FirewallVpnService.isRunning) {
            val wifiList = extractStringList(call.argument<List<*>>("allowedWifiPackages"))
            val mobileList = extractStringList(call.argument<List<*>>("allowedMobilePackages"))
            val intent = Intent(this, FirewallVpnService::class.java).apply {
                action = FirewallVpnService.ACTION_UPDATE_RULES
                putStringArrayListExtra(FirewallVpnService.EXTRA_ALLOWED_WIFI, wifiList)
                putStringArrayListExtra(FirewallVpnService.EXTRA_ALLOWED_MOBILE, mobileList)
            }
            startService(intent)
        }
        result.success(null)
    }

    private fun extractStringList(raw: List<*>?): ArrayList<String> {
        if (raw == null) return arrayListOf()
        val list = ArrayList<String>(raw.size)
        for (item in raw) {
            if (item is String) {
                list.add(item)
            }
        }
        return list
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
        FirewallVpnService.setStatusListener(null)
        clearPendingVpnRequest()
        executor.shutdownNow()
        super.onDestroy()
    }
}
