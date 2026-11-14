package ch.micheljung.shutterlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbPtpInterfaceTest {
    private val bulkIn = UsbEndpointSpec(index = 0, address = 0x81, type = 2, maxPacketSize = 512)
    private val bulkOut = UsbEndpointSpec(index = 1, address = 0x02, type = 2, maxPacketSize = 512)
    private val interrupt = UsbEndpointSpec(index = 2, address = 0x83, type = 3, maxPacketSize = 64)

    private fun ptp(
        index: Int = 0,
        endpoints: List<UsbEndpointSpec> = listOf(bulkIn, bulkOut, interrupt),
        interfaceClass: Int = 6,
        subclass: Int = 1,
        protocol: Int = 1,
    ) = UsbInterfaceSpec(index, index, interfaceClass, subclass, protocol, endpoints)

    @Test
    fun selectsTheEndpointsOfAPtpInterface() {
        val selected = UsbPtpInterface.select(listOf(ptp()), sdkInt = 34)

        assertNotNull(selected)
        assertEquals(0, selected!!.interfaceIndex)
        assertEquals(bulkIn, selected.bulkIn)
        assertEquals(bulkOut, selected.bulkOut)
        assertEquals(interrupt, selected.interrupt)
        assertEquals(128 * 1024, selected.maxTransfer)
    }

    @Test
    fun findsEndpointsInAnyOrder() {
        val selected = UsbPtpInterface.select(
            listOf(ptp(endpoints = listOf(interrupt, bulkOut, bulkIn))),
            sdkInt = 34,
        )

        assertEquals(bulkIn, selected!!.bulkIn)
        assertEquals(bulkOut, selected.bulkOut)
        assertEquals(interrupt, selected.interrupt)
    }

    @Test
    fun skipsInterfacesOfOtherClasses() {
        val mtp = ptp(index = 0, interfaceClass = 0xFF, subclass = 0xFF, protocol = 0)
        val selected = UsbPtpInterface.select(listOf(mtp, ptp(index = 1)), sdkInt = 34)

        assertEquals(1, selected!!.interfaceIndex)
    }

    @Test
    fun rejectsADeviceWithoutAPtpInterface() {
        assertNull(UsbPtpInterface.select(listOf(ptp(protocol = 0)), sdkInt = 34))
        assertNull(UsbPtpInterface.select(emptyList(), sdkInt = 34))
    }

    @Test
    fun rejectsAPtpInterfaceWithoutBothBulkEndpoints() {
        assertNull(UsbPtpInterface.select(listOf(ptp(endpoints = listOf(bulkIn, interrupt))), 34))
        assertNull(UsbPtpInterface.select(listOf(ptp(endpoints = listOf(bulkOut, interrupt))), 34))
    }

    @Test
    fun allowsAMissingInterruptEndpoint() {
        val selected = UsbPtpInterface.select(listOf(ptp(endpoints = listOf(bulkIn, bulkOut))), 34)

        assertNull(selected!!.interrupt)
    }

    @Test
    fun maxTransferIs16KiBBelowApi28() {
        assertEquals(16 * 1024, UsbPtpInterface.maxTransfer(512, sdkInt = 27))
        assertEquals(128 * 1024, UsbPtpInterface.maxTransfer(512, sdkInt = 28))
    }

    @Test
    fun maxTransferIsAMultipleOfThePacketSize() {
        val maxTransfer = UsbPtpInterface.maxTransfer(1000, sdkInt = 34)

        assertEquals(0, maxTransfer % 1000)
        assertTrue(maxTransfer in 64 * 1024..128 * 1024)
        assertEquals(128 * 1024, UsbPtpInterface.maxTransfer(64, sdkInt = 34))
    }

    @Test
    fun recognisesTheEndpointDirection() {
        assertTrue(bulkIn.isIn)
        assertFalse(bulkOut.isIn)
    }
}
