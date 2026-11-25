package com.netguard.netguard_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.util.concurrent.ConcurrentHashMap

class FirewallVpnService : VpnService() {
    enum class NetworkType(val wireValue: String) {
        WIFI("wifi"),
        MOBILE("mobile"),
        NONE("none"),
    }

    companion object {
        const val ACTION_START = "com.netguard.netguard_flutter.action.START"
        const val ACTION_UPDATE_RULES = "com.netguard.netguard_flutter.action.UPDATE_RULES"
        const val ACTION_STOP = "com.netguard.netguard_flutter.action.STOP"

        const val EXTRA_ALLOWED_WIFI = "allowedWifiPackages"
        const val EXTRA_ALLOWED_MOBILE = "allowedMobilePackages"

        private const val CHANNEL_ID = "netguard_firewall_channel"
        private const val NOTIFICATION_ID = 1001

        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var activeNetworkType: NetworkType = NetworkType.NONE
            private set

        @Volatile
        private var statusListener: ((Boolean, NetworkType) -> Unit)? = null

        fun setStatusListener(listener: ((Boolean, NetworkType) -> Unit)?) {
            statusListener = listener
        }

        private fun notifyStatusChanged() {
            val active = isRunning
            val network = activeNetworkType
            mainHandler.post {
                statusListener?.invoke(active, network)
            }
        }

        fun detectCurrentNetworkType(context: Context): NetworkType {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return NetworkType.NONE

            @Suppress("DEPRECATION")
            val networks = cm.allNetworks
            var hasWifi = false
            var hasMobile = false
            var hasValidatedWifi = false
            var hasValidatedMobile = false

            for (network in networks) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                    !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                ) {
                    continue
                }

                val isValidated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                } else {
                    true
                }

                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    hasWifi = true
                    if (isValidated) hasValidatedWifi = true
                }
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                    hasMobile = true
                    if (isValidated) hasValidatedMobile = true
                }
            }

            return when {
                hasValidatedWifi -> NetworkType.WIFI
                hasValidatedMobile -> NetworkType.MOBILE
                hasWifi -> NetworkType.WIFI
                hasMobile -> NetworkType.MOBILE
                else -> NetworkType.NONE
            }
        }
    }

    private val vpnLock = Any()
    private val trackedNetworks = ConcurrentHashMap<Network, NetworkCapabilities>()

    private var vpnInterface: ParcelFileDescriptor? = null
    private var allowedWifiPackages: Set<String> = emptySet()
    private var allowedMobilePackages: Set<String> = emptySet()
    private var networkCallbackRegistered = false
    private var isForegroundStarted = false

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            val caps = cm.getNetworkCapabilities(network) ?: return
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                trackedNetworks[network] = caps
                handleNetworkTopologyChanged()
            }
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) {
            if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                trackedNetworks[network] = networkCapabilities
                handleNetworkTopologyChanged()
            }
        }

        override fun onLost(network: Network) {
            trackedNetworks.remove(network)
            handleNetworkTopologyChanged()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                // Must enter foreground immediately when started via startForegroundService.
                startForegroundCompat(detectCurrentNetworkType(this))

                if (prepare(this) != null) {
                    stopVpnInternal()
                    return START_NOT_STICKY
                }

                updateRulesFromIntent(intent)
                synchronized(vpnLock) {
                    isRunning = true
                    registerPhysicalNetworkCallback()
                    activeNetworkType = resolveTrackedNetworkType()
                    updateNotification(activeNetworkType)
                    if (!establishVpnLocked()) {
                        stopVpnInternalLocked()
                        return START_NOT_STICKY
                    }
                }
                notifyStatusChanged()
            }

            ACTION_UPDATE_RULES -> {
                updateRulesFromIntent(intent)
                synchronized(vpnLock) {
                    if (isRunning) {
                        establishVpnLocked()
                    }
                }
            }

            ACTION_STOP, null -> {
                stopVpnInternal()
            }
        }

        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopVpnInternal()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopVpnInternal(stopService = false)
        super.onDestroy()
    }

    private fun updateRulesFromIntent(intent: Intent) {
        val wifiList = intent.getStringArrayListExtra(EXTRA_ALLOWED_WIFI) ?: emptyList()
        val mobileList = intent.getStringArrayListExtra(EXTRA_ALLOWED_MOBILE) ?: emptyList()
        synchronized(vpnLock) {
            allowedWifiPackages = wifiList.toHashSet()
            allowedMobilePackages = mobileList.toHashSet()
        }
    }

    private fun registerPhysicalNetworkCallback() {
        if (networkCallbackRegistered) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return

        trackedNetworks.clear()
        @Suppress("DEPRECATION")
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                trackedNetworks[network] = caps
            }
        }

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        cm.registerNetworkCallback(request, networkCallback)
        networkCallbackRegistered = true
    }

    private fun unregisterPhysicalNetworkCallback() {
        if (!networkCallbackRegistered) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        try {
            cm?.unregisterNetworkCallback(networkCallback)
        } catch (_: Exception) {
        } finally {
            trackedNetworks.clear()
            networkCallbackRegistered = false
        }
    }

    private fun resolveTrackedNetworkType(): NetworkType {
        var hasWifi = false
        var hasMobile = false
        var hasValidatedWifi = false
        var hasValidatedMobile = false

        for (caps in trackedNetworks.values) {
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                continue
            }

            val isValidated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            } else {
                true
            }

            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                hasWifi = true
                if (isValidated) hasValidatedWifi = true
            }
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                hasMobile = true
                if (isValidated) hasValidatedMobile = true
            }
        }

        return when {
            hasValidatedWifi -> NetworkType.WIFI
            hasValidatedMobile -> NetworkType.MOBILE
            hasWifi -> NetworkType.WIFI
            hasMobile -> NetworkType.MOBILE
            else -> NetworkType.NONE
        }
    }

    private fun handleNetworkTopologyChanged() {
        var changed = false
        var established = true
        synchronized(vpnLock) {
            if (!isRunning) return
            val nextNetworkType = resolveTrackedNetworkType()
            if (nextNetworkType != activeNetworkType) {
                activeNetworkType = nextNetworkType
                updateNotification(nextNetworkType)
                established = establishVpnLocked()
                if (!established) {
                    stopVpnInternalLocked()
                }
                changed = true
            }
        }
        if (changed) {
            notifyStatusChanged()
        }
    }

    private fun establishVpnLocked(): Boolean {
        val builder = Builder()
            .setSession("NetGuard Firewall")
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)

        try {
            builder.addAddress("fd00::2", 128)
            builder.addRoute("::", 0)
        } catch (_: Exception) {
            // Keep IPv4-only sinkhole if device rejects IPv6 tunnel route.
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(activeNetworkType == NetworkType.MOBILE)
        }

        val allowedForActiveNetwork = when (activeNetworkType) {
            NetworkType.WIFI -> allowedWifiPackages
            NetworkType.MOBILE -> allowedMobilePackages
            NetworkType.NONE -> emptySet()
        }

        val disallowedPackages = HashSet<String>(allowedForActiveNetwork.size + 1)
        disallowedPackages.add(applicationContext.packageName)
        disallowedPackages.addAll(allowedForActiveNetwork)

        for (packageName in disallowedPackages) {
            try {
                builder.addDisallowedApplication(packageName)
            } catch (_: PackageManager.NameNotFoundException) {
                // Skip packages not present on the device.
            }
        }

        val newInterface = try {
            builder.establish()
        } catch (_: Exception) {
            null
        } ?: return false

        val previousInterface = vpnInterface
        vpnInterface = newInterface
        try {
            previousInterface?.close()
        } catch (_: Exception) {
        }
        return true
    }

    private fun stopVpnInternal(stopService: Boolean = true) {
        synchronized(vpnLock) {
            stopVpnInternalLocked()
        }
        if (stopService) {
            stopSelf()
        }
        notifyStatusChanged()
    }

    private fun stopVpnInternalLocked() {
        unregisterPhysicalNetworkCallback()
        try {
            vpnInterface?.close()
        } catch (_: Exception) {
        } finally {
            vpnInterface = null
        }
        isRunning = false
        activeNetworkType = detectCurrentNetworkType(this)
        if (isForegroundStarted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            isForegroundStarted = false
        }
    }

    private fun startForegroundCompat(networkType: NetworkType) {
        ensureNotificationChannel()
        val notification = buildNotification(networkType)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isForegroundStarted = true
    }

    private fun updateNotification(networkType: NetworkType) {
        if (!isForegroundStarted) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(networkType))
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "NetGuard Firewall",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Persistent status notification while the local VPN firewall is active."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(networkType: NetworkType): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

        val statusText = when (networkType) {
            NetworkType.WIFI -> "Active • Filtering on Wi-Fi"
            NetworkType.MOBILE -> "Active • Filtering on Mobile Data"
            NetworkType.NONE -> "Active • Waiting for network"
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("NetGuard Firewall")
            .setContentText(statusText)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }
}
