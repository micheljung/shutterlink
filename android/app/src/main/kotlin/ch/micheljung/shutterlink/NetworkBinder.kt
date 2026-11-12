package ch.micheljung.shutterlink

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class NetworkBinder(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "bindToWifi" -> {
                    val network = findWifiNetwork()
                    if (network == null) {
                        result.error(NO_WIFI, "No Wi-Fi network available", null)
                    } else if (!connectivity.bindProcessToNetwork(network)) {
                        result.error(BIND_FAILED, "Could not bind to Wi-Fi", null)
                    } else {
                        result.success(gatewayOf(network))
                    }
                }
                "unbind" -> {
                    connectivity.bindProcessToNetwork(null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
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
        const val NO_WIFI = "no_wifi"
        const val BIND_FAILED = "bind_failed"
    }
}
