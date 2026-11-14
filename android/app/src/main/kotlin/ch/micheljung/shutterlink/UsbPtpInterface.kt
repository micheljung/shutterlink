package ch.micheljung.shutterlink

/** An endpoint as [UsbPtpInterface.select] sees it, free of Android types so it unit-tests on the JVM. */
data class UsbEndpointSpec(
    val index: Int,
    val address: Int,
    val type: Int,
    val maxPacketSize: Int,
) {
    val isIn: Boolean get() = address and UsbPtpInterface.DIR_IN != 0
}

/** A USB interface with its endpoints. */
data class UsbInterfaceSpec(
    val index: Int,
    val id: Int,
    val interfaceClass: Int,
    val subclass: Int,
    val protocol: Int,
    val endpoints: List<UsbEndpointSpec>,
)

/** The PTP interface of a device and the endpoints the bridge talks to. */
data class UsbPtpEndpoints(
    val interfaceIndex: Int,
    val bulkIn: UsbEndpointSpec,
    val bulkOut: UsbEndpointSpec,
    val interrupt: UsbEndpointSpec?,
    val maxTransfer: Int,
)

object UsbPtpInterface {
    /** The still-image capture class, subclass and protocol of a PTP camera. */
    const val STILL_IMAGE_CLASS = 6
    const val STILL_IMAGE_SUBCLASS = 1
    const val PTP_PROTOCOL = 1

    const val DIR_IN = 0x80
    const val XFER_BULK = 2
    const val XFER_INT = 3

    const val DEFAULT_MAX_TRANSFER = 128 * 1024

    /** Below API 28 a single `bulkTransfer` moves at most 16 KiB. */
    const val LEGACY_MAX_TRANSFER = 16 * 1024
    const val LEGACY_SDK_BELOW = 28

    /** Picks the first still-image interface with a bulk-in and a bulk-out endpoint. */
    fun select(interfaces: List<UsbInterfaceSpec>, sdkInt: Int): UsbPtpEndpoints? {
        for (spec in interfaces) {
            if (!isPtp(spec)) continue
            val bulkIn = spec.endpoints.firstOrNull { it.type == XFER_BULK && it.isIn } ?: continue
            val bulkOut = spec.endpoints.firstOrNull { it.type == XFER_BULK && !it.isIn } ?: continue
            val interrupt = spec.endpoints.firstOrNull { it.type == XFER_INT && it.isIn }
            return UsbPtpEndpoints(
                interfaceIndex = spec.index,
                bulkIn = bulkIn,
                bulkOut = bulkOut,
                interrupt = interrupt,
                maxTransfer = maxTransfer(bulkIn.maxPacketSize, sdkInt),
            )
        }
        return null
    }

    fun isPtp(spec: UsbInterfaceSpec): Boolean =
        spec.interfaceClass == STILL_IMAGE_CLASS &&
            spec.subclass == STILL_IMAGE_SUBCLASS &&
            spec.protocol == PTP_PROTOCOL

    /** The largest read the bridge asks for at once: a multiple of [maxPacketSize]. */
    fun maxTransfer(maxPacketSize: Int, sdkInt: Int): Int {
        val limit = if (sdkInt < LEGACY_SDK_BELOW) LEGACY_MAX_TRANSFER else DEFAULT_MAX_TRANSFER
        if (maxPacketSize <= 0 || maxPacketSize >= limit) return limit
        return limit - limit % maxPacketSize
    }
}
