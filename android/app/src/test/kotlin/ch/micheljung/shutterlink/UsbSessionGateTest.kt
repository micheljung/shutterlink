package ch.micheljung.shutterlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UsbSessionGateTest {
    @Test
    fun letsTheOpenSessionThrough() {
        assertNull(UsbSessionGate.check(openId = 2, requestedId = 2))
    }

    @Test
    fun refusesAReplacedSession() {
        assertEquals(UsbSessionGate.Rejection.STALE, UsbSessionGate.check(openId = 2, requestedId = 1))
    }

    @Test
    fun refusesACallWithoutASession() {
        assertEquals(UsbSessionGate.Rejection.STALE, UsbSessionGate.check(openId = 2, requestedId = null))
    }

    @Test
    fun reportsNothingOpen() {
        assertEquals(UsbSessionGate.Rejection.NOT_OPEN, UsbSessionGate.check(openId = null, requestedId = 1))
    }
}
