package ru.mkulkov.brizfi

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsbReaderInterfaceTest {
    @Test fun acceptsStandardKindleMtp() {
        assertTrue(isKindleMtpInterface(0x1949, 0x9981, 6, 1, 1))
        assertFalse(isKindleMtpInterface(0x1949, 0x1234, 6, 1, 1))
    }

    @Test fun acceptsObservedKindleVendorMtp() {
        assertTrue(isKindleMtpInterface(0x1949, 0x9981, 255, 255, 0))
    }

    @Test fun acceptsOnlyObservedNookMassStorage() {
        assertTrue(isNookMassStorageInterface(0x2080, 0x0003, 8, 6, 80))
        assertFalse(isNookMassStorageInterface(0x2080, 0x0004, 8, 6, 80))
        assertFalse(isNookMassStorageInterface(0x1949, 0x9981, 8, 6, 80))
        assertFalse(isNookMassStorageInterface(0x2080, 0x0003, 6, 1, 1))
    }

    @Test fun rejectsOtherDevicesAndInterfaces() {
        assertFalse(isKindleMtpInterface(0x1234, 0x9981, 255, 255, 0))
        assertFalse(isKindleMtpInterface(0x1949, 0x1234, 255, 255, 0))
        assertFalse(isKindleMtpInterface(0x1949, 0x9981, 255, 255, 1))
        assertFalse(isKindleMtpInterface(0x1949, 0x9981, 8, 6, 80))
    }
}
