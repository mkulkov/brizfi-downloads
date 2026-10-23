package ru.mkulkov.brizfi

import org.junit.Assert.*
import org.junit.Test

class UsbReaderIdentificationTest {
    private val storage = listOf(UsbReaderIdentification.Interface(8, 6, 80))
    private fun device(manufacturer: String? = null, product: String? = null) =
        UsbReaderIdentification.Descriptor(65534, 1, manufacturer, product, storage)

    @Test fun actualPocketBookDescriptorIsDiscoveryOnly() {
        val reader = UsbReaderIdentification.discover(device("Obreey", "PB740-2"), null)
        assertEquals("pocketbook", reader.brand)
        assertEquals("PocketBook USB", reader.name)
        assertEquals("unknown", reader.profile)
        assertEquals("massStorage", reader.transport)
        assertTrue(reader.formats.isEmpty())
    }

    @Test fun genericStorageAndMisleadingNamesStayOther() {
        assertEquals("other", UsbReaderIdentification.discover(device(), null).brand)
        assertEquals("other", UsbReaderIdentification.discover(device("notpocketbook", "microboox"), null).brand)
        assertEquals("other", UsbReaderIdentification.discover(device("Obreey", "Disk"), null).brand)
        val nonFileDevice = UsbReaderIdentification.discover(device().copy(interfaces = emptyList()), null)
        assertEquals("unsupported", nonFileDevice.transport)
        assertEquals("other", nonFileDevice.brand)
        assertTrue(nonFileDevice.formats.isEmpty())
    }

    @Test fun knownProfilesKeepWriteCapabilities() {
        for (profile in listOf(UsbReaderProfile.KINDLE, UsbReaderProfile.NOOK)) {
            val reader = UsbReaderIdentification.discover(device("Obreey", "PB740-2"), profile)
            assertEquals(profile.key, reader.brand)
            assertEquals(profile.key, reader.profile)
            assertEquals(profile.transport, reader.transport)
            assertEquals(profile.formats, reader.formats.toSet())
        }
        assertNull(UsbReaderProfile.forUsb(65534, 1))
    }

    @Test fun mtpCandidateAndBrandTokensAreDiscoveryOnly() {
        for ((name, brand) in listOf("Kindle" to "kindle", "NOOK" to "nook", "Kobo" to "kobo",
                "PocketBook" to "pocketbook", "Onyx BOOX" to "onyx")) {
            val descriptor = device(name).copy(interfaces = listOf(UsbReaderIdentification.Interface(6, 1, 1)))
            val reader = UsbReaderIdentification.discover(descriptor, null)
            assertEquals(brand, reader.brand)
            assertEquals("mtp", reader.transport)
            assertTrue(reader.formats.isEmpty())
        }
    }

    @Test fun identityIsStablePrivateAndFamilyScopedWithoutSerial() {
        val descriptor = device("Obreey", "PB740-2")
        val identity = UsbReaderIdentification.identity(descriptor, null)
        assertFalse(identity.second)
        assertTrue(identity.first.matches(Regex("usb:[a-f0-9]{64}")))
        assertEquals(identity, UsbReaderIdentification.identity(descriptor, ""))
        assertEquals(identity, UsbReaderIdentification.identity(device("OBREEY", "pb740-2"), null))
        assertNotEquals(identity, UsbReaderIdentification.identity(device("Obreey", "PB700"), null))
        assertTrue(UsbReaderIdentification.identity(descriptor, "private-serial").second)
        assertFalse(UsbReaderIdentification.identity(descriptor, " ").second)
        assertFalse(UsbReaderIdentification.identity(descriptor, "x".repeat(257)).second)
    }
    @Test fun genericTransportDoesNotOverrideDescriptorBrandOrPromiseConversion() {
        val reader = UsbReaderIdentification.discover(device("Obreey", "PB740-2"), UsbReaderProfile.GENERIC_STORAGE)
        assertEquals("pocketbook", reader.brand)
        assertEquals("generic-storage", reader.profile)
        assertEquals(setOf("azw3", "mobi", "epub", "pdf", "txt"), reader.formats.toSet())
    }
}
