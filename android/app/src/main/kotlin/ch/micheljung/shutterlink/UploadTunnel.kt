package ch.micheljung.shutterlink

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

class UploadTunnel(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val executor = Executors.newCachedThreadPool()
    private val mainThread = Handler(Looper.getMainLooper())
    private val random = SecureRandom()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "openTunnel") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val host = call.argument<String>("host")
            val port = call.argument<Int>("port")
            val allowMetered = call.argument<Boolean>("allowMetered") ?: false
            if (host == null || port == null) {
                result.error(INVALID_ARGUMENTS, "Missing host or port", null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val tunnel = open(host, port, allowMetered)
                    mainThread.post { result.success(tunnel) }
                } catch (e: NoNetworkException) {
                    mainThread.post { result.error(NO_NETWORK, e.message, null) }
                } catch (e: Exception) {
                    mainThread.post { result.error(TUNNEL_FAILED, e.message, null) }
                }
            }
        }
    }

    private fun open(host: String, port: Int, allowMetered: Boolean): Map<String, Any> {
        val cleanup = Cleanup()
        try {
            val network = selectNetwork(allowMetered, cleanup)
            val address = network.getAllByName(host).first()
            val upstream = network.socketFactory.createSocket().also(cleanup::add)
            upstream.connect(InetSocketAddress(address, port), TIMEOUT_MS)
            val server = ServerSocket(0, 1, InetAddress.getByName(LOOPBACK)).also(cleanup::add)
            server.soTimeout = TIMEOUT_MS
            val token = ByteArray(TOKEN_BYTES).also(random::nextBytes).toHex()
            executor.execute { serve(server, upstream, token, cleanup) }
            return mapOf(
                "port" to server.localPort,
                "token" to token,
                "networkType" to networkType(network),
            )
        } catch (e: Exception) {
            cleanup.run()
            throw e
        }
    }

    private fun selectNetwork(allowMetered: Boolean, cleanup: Cleanup): Network {
        @Suppress("DEPRECATION")
        connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)?.let {
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) &&
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            } == true
        }?.let { return it }
        if (!allowMetered) throw NoNetworkException("No unmetered internet network")
        val available = CompletableFuture<Network>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                available.complete(network)
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, callback)
        cleanup.add { connectivity.unregisterNetworkCallback(callback) }
        return try {
            available.get(TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
        } catch (e: TimeoutException) {
            throw NoNetworkException("No cellular network available")
        }
    }

    private fun serve(server: ServerSocket, upstream: Socket, token: String, cleanup: Cleanup) {
        try {
            val client = server.accept().also(cleanup::add)
            server.close()
            client.soTimeout = TIMEOUT_MS
            val received = ByteArray(token.length)
            client.getInputStream().readFully(received)
            if (!MessageDigest.isEqual(received, token.toByteArray(Charsets.US_ASCII))) {
                throw IOException("Invalid tunnel token")
            }
            client.soTimeout = 0
            executor.execute { pipe(upstream.getInputStream(), client.getOutputStream(), cleanup) }
            pipe(client.getInputStream(), upstream.getOutputStream(), cleanup)
        } catch (e: Exception) {
            cleanup.run()
        }
    }

    private fun pipe(input: InputStream, output: OutputStream, cleanup: Cleanup) {
        try {
            input.copyTo(output)
        } catch (_: IOException) {
        } finally {
            cleanup.run()
        }
    }

    private fun networkType(network: Network): String {
        val capabilities = connectivity.getNetworkCapabilities(network) ?: return "unknown"
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }

    private class Cleanup : Runnable {
        private val done = AtomicBoolean(false)
        private val resources = mutableListOf<() -> Unit>()

        @Synchronized
        fun add(resource: Closeable) = add { resource.close() }

        @Synchronized
        fun add(action: () -> Unit) {
            if (done.get()) action() else resources += action
        }

        @Synchronized
        override fun run() {
            if (!done.compareAndSet(false, true)) return
            resources.forEach { runCatching(it) }
        }
    }

    private class NoNetworkException(message: String) : IOException(message)

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/upload_tunnel"
        const val LOOPBACK = "127.0.0.1"
        const val TOKEN_BYTES = 32
        const val TIMEOUT_MS = 10_000
        const val INVALID_ARGUMENTS = "invalid_arguments"
        const val NO_NETWORK = "no_network"
        const val TUNNEL_FAILED = "tunnel_failed"
    }
}

private fun InputStream.readFully(buffer: ByteArray) {
    var offset = 0
    while (offset < buffer.size) {
        val read = read(buffer, offset, buffer.size - offset)
        if (read < 0) throw IOException("Tunnel closed before token")
        offset += read
    }
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
