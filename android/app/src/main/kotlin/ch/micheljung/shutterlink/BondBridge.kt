package ch.micheljung.shutterlink

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The phone's Bluetooth bond with a camera. The camera takes remote buttons
 * only over an encrypted link, and Android asks the user to confirm the bond,
 * so the remote waits for it before it calls itself connected.
 */
@SuppressLint("MissingPermission") // Dart asks for BLUETOOTH_CONNECT first.
class BondBridge(private val context: Context) {
    private var events: EventChannel.EventSink? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device = deviceOf(intent) ?: return
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)
            events?.success(mapOf("address" to device.address, "state" to name(state)))
        }
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val address = call.argument<String>("address")
            val device = address?.let(::device)
            if (device == null) {
                result.error("unknown", "No Bluetooth device $address", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "bondState" -> result.success(name(device.bondState))
                    "createBond" -> result.success(device.createBond())
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("denied", e.message, null)
            }
        }
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    // The Bluetooth process sends it under its own uid, which a
                    // not-exported receiver never hears from. Only the system
                    // may send this protected action anyway.
                    context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
                } else {
                    context.registerReceiver(receiver, filter)
                }
            }

            override fun onCancel(arguments: Any?) {
                events = null
                context.unregisterReceiver(receiver)
            }
        })
    }

    private fun device(address: String): BluetoothDevice? {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return null
        return try {
            adapter.getRemoteDevice(address)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun deviceOf(intent: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }

    private fun name(state: Int): String = when (state) {
        BluetoothDevice.BOND_BONDED -> "bonded"
        BluetoothDevice.BOND_BONDING -> "bonding"
        else -> "none"
    }

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/bond"
        const val EVENTS_CHANNEL = "ch.micheljung.shutterlink/bond_states"
    }
}
