package ch.micheljung.shutterlink

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.hardware.usb.UsbRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A thin pipe to a PTP camera on the USB cable. Dart frames the containers and
 * owns every transaction timeout; this side only moves whole transfers and
 * reports devices coming and going.
 */
class UsbBridge(private val context: Context) {
    private val usb = context.getSystemService(UsbManager::class.java)
    private val mainThread = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    /** `attached` events that arrived before Dart listened, e.g. on a cold start from the cable. */
    private val pending = mutableListOf<Map<String, Any?>>()

    /** Devices already announced, so the manifest intent and the receiver report a device once. */
    private val reported = mutableSetOf<String>()
    private var session: Session? = null
    private var lastSessionId = 0
    private var receiverRegistered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> deviceOf(intent)?.let(::reportAttached)
                UsbManager.ACTION_USB_DEVICE_DETACHED -> deviceOf(intent)?.let(::reportDetached)
                ACTION_USB_PERMISSION -> deviceOf(intent)?.let {
                    emit(
                        mapOf(
                            "type" to PERMISSION,
                            "deviceName" to it.deviceName,
                            "granted" to intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false),
                        ),
                    )
                }
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                pending.forEach(sink::success)
                pending.clear()
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(::handle)
        registerReceiver()
    }

    fun dispose() {
        if (receiverRegistered) {
            context.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        session?.close()
        session = null
        events = null
        pending.clear()
        reported.clear()
    }

    /** Takes the `USB_DEVICE_ATTACHED` intent that started or resumed the Activity. */
    fun onIntent(intent: Intent?) {
        if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        deviceOf(intent)?.let(::reportAttached)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(
                usb.deviceList.values.filter(::hasPtpInterface).map(::describe),
            )
            "requestPermission" -> requestPermission(call, result)
            "open" -> open(call, result)
            "close" -> {
                // A pipe that a later open replaced must not close its successor.
                if (UsbSessionGate.check(session?.id, call.argument<Int>("sessionId")) == null) {
                    session?.close()
                    session = null
                }
                result.success(null)
            }
            "bulkOut", "bulkIn", "clearHalt", "classRequest", "drainIn" -> {
                val session = session
                when (UsbSessionGate.check(session?.id, call.argument<Int>("sessionId"))) {
                    UsbSessionGate.Rejection.NOT_OPEN ->
                        result.error(NOT_OPEN, "No USB device is open", null)
                    UsbSessionGate.Rejection.STALE -> result.error(USB_IO, "stale session", null)
                    null -> session!!.handle(call, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(call: MethodCall, result: MethodChannel.Result) {
        val device = deviceNamed(call.argument<String>("deviceName"))
        if (device == null) {
            result.error(NO_DEVICE, "The USB device is gone", null)
            return
        }
        if (usb.hasPermission(device)) {
            result.success(true)
            return
        }
        // Works without an Activity too; Dart does not wait for the answer.
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags))
        result.success(false)
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        session?.close()
        session = null
        val device = deviceNamed(call.argument<String>("deviceName"))
        if (device == null) {
            result.error(NO_DEVICE, "The USB device is gone", null)
            return
        }
        if (!usb.hasPermission(device)) {
            result.error(NO_PERMISSION, "No permission for the USB device", null)
            return
        }
        val selected = UsbPtpInterface.select(specsOf(device), Build.VERSION.SDK_INT)
        if (selected == null) {
            result.error(NO_PTP_INTERFACE, "The USB device has no PTP interface", null)
            return
        }
        val connection = usb.openDevice(device)
        if (connection == null) {
            result.error(OPEN_FAILED, "Could not open the USB device", null)
            return
        }
        val usbInterface = device.getInterface(selected.interfaceIndex)
        if (!connection.claimInterface(usbInterface, true)) {
            connection.close()
            result.error(CLAIM_FAILED, "Could not claim the PTP interface", null)
            return
        }
        val opened = Session(
            id = ++lastSessionId,
            deviceName = device.deviceName,
            connection = connection,
            usbInterface = usbInterface,
            bulkIn = usbInterface.getEndpoint(selected.bulkIn.index),
            bulkOut = usbInterface.getEndpoint(selected.bulkOut.index),
            interrupt = selected.interrupt?.let { usbInterface.getEndpoint(it.index) },
            maxTransfer = selected.maxTransfer,
        )
        session = opened
        result.success(
            mapOf(
                "sessionId" to opened.id,
                "maxPacketSize" to opened.maxPacketSize,
                "maxTransfer" to opened.maxTransfer,
            ),
        )
    }

    private fun reportAttached(device: UsbDevice) {
        if (!hasPtpInterface(device) || !reported.add(device.deviceName)) return
        val event = mapOf("type" to ATTACHED, "device" to describe(device))
        val sink = events
        if (sink == null) pending.add(event) else sink.success(event)
    }

    private fun reportDetached(device: UsbDevice) {
        val name = device.deviceName
        val wasReported = reported.remove(name)
        pending.removeAll { (it["device"] as Map<*, *>)["deviceName"] == name }
        if (session?.deviceName == name) {
            session?.close()
            session = null
        }
        if (wasReported || hasPtpInterface(device)) {
            emit(mapOf("type" to DETACHED, "deviceName" to name))
        }
    }

    private fun emit(event: Map<String, Any?>) {
        events?.success(event)
    }

    private fun registerReceiver() {
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(ACTION_USB_PERMISSION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    private fun deviceNamed(name: String?): UsbDevice? = name?.let { usb.deviceList[it] }

    private fun describe(device: UsbDevice): Map<String, Any?> {
        val permitted = usb.hasPermission(device)
        return mapOf(
            "deviceName" to device.deviceName,
            "vendorId" to device.vendorId,
            "productId" to device.productId,
            "serial" to if (permitted) serialOf(device) else null,
            "product" to device.productName,
            "hasPermission" to permitted,
        )
    }

    private fun serialOf(device: UsbDevice): String? = try {
        device.serialNumber
    } catch (_: SecurityException) {
        null
    }

    private fun hasPtpInterface(device: UsbDevice): Boolean =
        specsOf(device).any(UsbPtpInterface::isPtp)

    private fun specsOf(device: UsbDevice): List<UsbInterfaceSpec> =
        (0 until device.interfaceCount).map { i ->
            val usbInterface = device.getInterface(i)
            UsbInterfaceSpec(
                index = i,
                id = usbInterface.id,
                interfaceClass = usbInterface.interfaceClass,
                subclass = usbInterface.interfaceSubclass,
                protocol = usbInterface.interfaceProtocol,
                endpoints = (0 until usbInterface.endpointCount).map { j ->
                    val endpoint = usbInterface.getEndpoint(j)
                    UsbEndpointSpec(
                        index = j,
                        address = endpoint.address,
                        type = endpoint.type,
                        maxPacketSize = endpoint.maxPacketSize,
                    )
                },
            )
        }

    @Suppress("DEPRECATION")
    private fun deviceOf(intent: Intent): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    /**
     * One open device. Bulk transfers run one at a time on their own thread,
     * interrupt reads on another; [close] unblocks both by closing the
     * connection, and no result is posted as success after it.
     */
    private inner class Session(
        val id: Int,
        val deviceName: String,
        private val connection: UsbDeviceConnection,
        private val usbInterface: UsbInterface,
        private val bulkIn: UsbEndpoint,
        private val bulkOut: UsbEndpoint,
        interrupt: UsbEndpoint?,
        val maxTransfer: Int,
    ) {
        val maxPacketSize: Int = bulkIn.maxPacketSize
        private val lock = Any()
        private var closed = false
        private val bulkThread = HandlerThread("shutterlink-usb-bulk").apply { start() }
        private val bulk = Handler(bulkThread.looper)
        private val interruptRequest: UsbRequest? = interrupt?.let { endpoint ->
            UsbRequest().takeIf { it.initialize(connection, endpoint) }
        }
        private var interruptReleased = false

        init {
            interruptRequest?.let { request ->
                Thread({ readInterrupts(request) }, "shutterlink-usb-interrupt").start()
            }
        }

        private val isClosed: Boolean get() = synchronized(lock) { closed }

        fun handle(call: MethodCall, result: MethodChannel.Result) {
            val work: () -> Any? = when (call.method) {
                "bulkOut" -> {
                    val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0);
                    { bulkOut(bytes) }
                }
                "bulkIn" -> {
                    val maxLength = call.argument<Int>("maxLength") ?: maxTransfer
                    val clock = TransferClock(call.argument<Boolean>("timing") ?: false);
                    { clock.reply(bulkIn(maxLength, clock)) }
                }
                "clearHalt" -> ({ clearHalt() })
                "classRequest" -> {
                    val request = call.argument<Int>("request") ?: 0
                    val deviceToHost = call.argument<Boolean>("deviceToHost") ?: false
                    val value = call.argument<Int>("value") ?: 0
                    val length = call.argument<Int>("length") ?: 0
                    val data = call.argument<ByteArray>("data");
                    { mapOf("bytes" to classRequest(request, deviceToHost, value, length, data)) }
                }
                else -> ({ drainIn() })
            }
            val posted = bulk.post {
                val outcome = try {
                    Result.success(work())
                } catch (e: UsbIoException) {
                    Result.failure(e)
                }
                mainThread.post { reply(result, outcome) }
            }
            if (!posted) result.error(USB_IO, "The USB device was closed", null)
        }

        /** Called on the main thread. */
        fun close() {
            synchronized(lock) {
                if (closed) return
                closed = true
                if (!interruptReleased) interruptRequest?.cancel()
                connection.releaseInterface(usbInterface)
                connection.close()
            }
            bulkThread.quitSafely()
        }

        private fun reply(result: MethodChannel.Result, outcome: Result<Any?>) {
            when {
                isClosed -> result.error(USB_IO, "The USB device was closed", null)
                outcome.isSuccess -> result.success(outcome.getOrNull())
                else -> result.error(USB_IO, outcome.exceptionOrNull()?.message, null)
            }
        }

        private fun checkOpen() {
            if (isClosed) throw UsbIoException("closed")
        }

        private fun bulkOut(bytes: ByteArray): Any? {
            var offset = 0
            while (offset < bytes.size) {
                checkOpen()
                val length = minOf(maxTransfer, bytes.size - offset)
                val written = connection.bulkTransfer(bulkOut, bytes, offset, length, 0)
                if (written < 0) throw UsbIoException("bulkOut failed")
                offset += written
            }
            // A transfer of whole packets ends with a zero-length packet.
            if (bytes.isNotEmpty() && bytes.size % bulkOut.maxPacketSize == 0) {
                if (connection.bulkTransfer(bulkOut, bytes, 0, 0, 0) < 0) {
                    throw UsbIoException("bulkOut failed")
                }
            }
            return null
        }

        /**
         * Reads one whole transfer: whole packets until a short one arrives or
         * [maxLength] is reached. Has no timeout; [close] ends it.
         */
        private fun bulkIn(maxLength: Int, clock: TransferClock): ByteArray {
            val limit = maxOf(maxPacketSize, maxLength - maxLength % maxPacketSize)
            val buffer = ByteArray(limit)
            var offset = 0
            while (offset < limit) {
                checkOpen()
                val requested = minOf(maxTransfer, limit - offset)
                val read = clock.measure {
                    connection.bulkTransfer(bulkIn, buffer, offset, requested, 0)
                }
                if (read < 0) throw UsbIoException("bulkIn failed")
                offset += read
                if (read < requested) break
            }
            return buffer.copyOf(offset)
        }

        private fun clearHalt(): Any? {
            for (endpoint in listOf(bulkIn, bulkOut)) {
                checkOpen()
                val status = connection.controlTransfer(
                    ENDPOINT_OUT_STANDARD,
                    CLEAR_FEATURE,
                    ENDPOINT_HALT,
                    endpoint.address,
                    null,
                    0,
                    CONTROL_TIMEOUT_MS,
                )
                if (status < 0) throw UsbIoException("clearHalt failed")
            }
            return null
        }

        /** A still-image class request; Android reports a stall as any other failure. */
        private fun classRequest(
            request: Int,
            deviceToHost: Boolean,
            value: Int,
            length: Int,
            data: ByteArray?,
        ): ByteArray {
            checkOpen()
            val buffer = if (deviceToHost) ByteArray(length) else data ?: ByteArray(0)
            val transferred = connection.controlTransfer(
                if (deviceToHost) CLASS_IN else CLASS_OUT,
                request,
                value,
                usbInterface.id,
                buffer,
                buffer.size,
                CONTROL_TIMEOUT_MS,
            )
            if (transferred < 0) throw UsbIoException("class request 0x${request.toString(16)} failed")
            return if (deviceToHost) buffer.copyOf(transferred) else ByteArray(0)
        }

        /** Discards whatever the camera still had queued; the only read with a timeout. */
        private fun drainIn(): Int {
            val buffer = ByteArray(maxTransfer)
            var discarded = 0
            while (true) {
                checkOpen()
                val read = connection.bulkTransfer(bulkIn, buffer, 0, buffer.size, DRAIN_TIMEOUT_MS)
                if (read <= 0) return discarded
                discarded += read
            }
        }

        private fun readInterrupts(request: UsbRequest) {
            val buffer = ByteBuffer.allocate(INTERRUPT_BUFFER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            try {
                while (true) {
                    buffer.clear()
                    val queued = synchronized(lock) { !closed && queue(request, buffer) }
                    if (!queued) break
                    val done = try {
                        connection.requestWait()
                    } catch (_: RuntimeException) {
                        null
                    }
                    if (done == null || isClosed) break
                    val length = receivedLength(buffer)
                    if (length <= 0) continue
                    val bytes = buffer.array().copyOf(length)
                    mainThread.post {
                        if (!isClosed) emit(mapOf("type" to INTERRUPT, "bytes" to bytes))
                    }
                }
            } finally {
                synchronized(lock) {
                    interruptReleased = true
                    request.close()
                }
            }
        }

        @Suppress("DEPRECATION")
        private fun queue(request: UsbRequest, buffer: ByteBuffer): Boolean =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                request.queue(buffer)
            } else {
                request.queue(buffer, buffer.capacity())
            }

        /** Before API 26 the request does not report its length; the event container does. */
        private fun receivedLength(buffer: ByteBuffer): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                buffer.position()
            } else {
                buffer.getInt(0).coerceIn(0, buffer.capacity())
            }
    }

    private class UsbIoException(message: String) : Exception(message)

    private companion object {
        const val CHANNEL = "ch.micheljung.shutterlink/usb"
        const val EVENTS_CHANNEL = "ch.micheljung.shutterlink/usb/events"
        const val ACTION_USB_PERMISSION = "ch.micheljung.shutterlink.USB_PERMISSION"

        const val ATTACHED = "attached"
        const val DETACHED = "detached"
        const val PERMISSION = "permission"
        const val INTERRUPT = "interrupt"

        const val NO_DEVICE = "no_device"
        const val NO_PERMISSION = "no_permission"
        const val NO_PTP_INTERFACE = "no_ptp_interface"
        const val OPEN_FAILED = "open_failed"
        const val CLAIM_FAILED = "claim_failed"
        const val NOT_OPEN = "not_open"
        const val USB_IO = "usb_io"

        const val ENDPOINT_OUT_STANDARD = 0x02
        const val CLEAR_FEATURE = 1
        const val ENDPOINT_HALT = 0
        const val CLASS_OUT = 0x21
        const val CLASS_IN = 0xA1

        /** Bounds control transfers only; bulk reads have no timeout. */
        const val CONTROL_TIMEOUT_MS = 2000
        const val DRAIN_TIMEOUT_MS = 50
        const val INTERRUPT_BUFFER_SIZE = 1024
    }
}
