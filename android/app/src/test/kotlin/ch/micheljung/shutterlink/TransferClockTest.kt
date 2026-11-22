package ch.micheljung.shutterlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class TransferClockTest {
    private val bytes = byteArrayOf(1, 2, 3)

    @Test
    fun sumsTheTransfersOfOneRead() {
        val ticks = ArrayDeque(listOf(0L, 2_000L, 10_000L, 13_000L))
        val clock = TransferClock(enabled = true) { ticks.removeFirst() }
        assertEquals(7, clock.measure { 7 })
        clock.measure { }
        assertEquals(5L, clock.reply(bytes)["nativeMicros"])
    }

    @Test
    fun reportsNothingUnlessAsked() {
        val clock = TransferClock(enabled = false) { error("not timed") }
        clock.measure { }
        assertFalse(clock.reply(bytes).containsKey("nativeMicros"))
    }
}
