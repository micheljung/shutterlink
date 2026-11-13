package ch.micheljung.shutterlink

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class NetworkBinder(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val multicastLock = context.getSystemService(WifiManager::class.java)
        .createMulticastLock(MULTICAST_LOCK_TAG)
        .apply { setReferenceCounted(false) }
    private val mainThread = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var boundNetwork: Network? = null
    private var heldRequest: ConnectivityManager.NetworkCallback? = null

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "bindToWifi" -> {
                    val network = findWifiNetwork()
                    if (network == null) {
                        result.error(NO_WIFI, "No Wi-Fi network available", null)
                    } else if (!connectivity.bindProcessToNetwork(network)) {
                        result.error(BIND_FAILED, "Could not bind to Wi-Fi", null)
                    } else {
                        boundNetwork = network
                        if (call.argument<Boolean>("hold") == true) holdWifi()
                        result.success(gatewayOf(network))
                    }
                }
                "unbind" -> {
                    connectivity.bindProcessToNetwork(null)
                    boundNetwork = null
                    releaseWifi()
                    result.success(null)
                }
                "acquireMulticastLock" -> {
                    multicastLock.acquire()
                    result.success(null)
                }
                "releaseMulticastLock" -> {
                    if (multicastLock.isHeld) multicastLock.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Without a request of its own, the system may tear down a Wi-Fi without
     * internet once mobile data is requested or the screen turns off.
     */
    private fun holdWifi() {
        if (heldRequest != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onLost(network: Network) {
                mainThread.post {
                    if (network == boundNetwork) events?.success(LOST)
                }
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, callback)
        heldRequest = callback
    }

    private fun releaseWifi() {
        heldRequest?.let { connectivity.unregisterNetworkCallback(it) }
        heldRequest = null
    }

    @Suppress("DEPRECATION")
    private fun findWifiNetwork(): Network? = connectivity.allNetworks.firstOrNull {
        connectivity.getNetworkCapabilities(it)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun gatewayOf(network: Network): String? {
        val properties = connectivity.getLinkProperties(network) ?: return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            properties.dhcpServerAddress?.hostAddress?.let { return it }
        }
        return properties.routes
            .firstOrNull { it.isDefaultRoute && it.gateway?.isAnyLocalAddress == false }
            ?.gateway?.hostAddress
    }

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/network"
        const val EVENTS_CHANNEL = "ch.micheljung.shutterlink/network/events"
        const val LOST = "lost"
        const val NO_WIFI = "no_wifi"
        const val BIND_FAILED = "bind_failed"
        const val MULTICAST_LOCK_TAG = "shutterlink-ssdp"
    }
}
