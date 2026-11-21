package ch.micheljung.shutterlink

import java.util.concurrent.TimeUnit

/**
 * Sums the time spent inside native USB transfers of one read, so Dart can
 * tell how much of the read's round trip the platform channel cost.
 */
class TransferClock(private val enabled: Boolean, private val now: () -> Long = System::nanoTime) {
    private var nanos = 0L

    fun <T> measure(transfer: () -> T): T {
        if (!enabled) return transfer()
        val start = now()
        try {
            return transfer()
        } finally {
            nanos += now() - start
        }
    }

    fun reply(bytes: ByteArray): Map<String, Any> =
        if (enabled) {
            mapOf("bytes" to bytes, "nativeMicros" to TimeUnit.NANOSECONDS.toMicros(nanos))
        } else {
            mapOf("bytes" to bytes)
        }
}
