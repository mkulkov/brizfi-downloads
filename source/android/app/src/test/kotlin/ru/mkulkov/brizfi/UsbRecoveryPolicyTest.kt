package ru.mkulkov.brizfi

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class UsbRecoveryPolicyTest {
    private fun failure(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") }
        catch (error: UsbTransferFailure) { assertEquals(code, error.code) }
    }

    @Test fun healthyDoesNotReset() {
        val calls = mutableListOf<Boolean>()
        assertEquals(0, runUsbRecovery({ false }) { calls.add(it); 0 })
        assertEquals(listOf(false), calls)
    }

    @Test fun retriesOnlyConfirmedEp0FailureOnce() {
        val calls = mutableListOf<Boolean>()
        assertEquals(2, runUsbRecovery({ false }) { calls.add(it); if (it) 2 else 1 })
        assertEquals(listOf(false, true), calls)
    }

    @Test fun failedRecoveryDoesNotLoop() {
        val calls = mutableListOf<Boolean>()
        failure("usb_open_failed") { runUsbRecovery({ false }) { calls.add(it); 1 } }
        assertEquals(listOf(false, true), calls)
    }

    @Test fun busyPreservesSafFallbackAndDoesNotReset() {
        val calls = mutableListOf<Boolean>()
        failure("usb_busy") { runUsbRecovery({ false }) { calls.add(it); -2 } }
        assertEquals(listOf(false), calls)
    }

    @Test fun otherErrorsDoNotReset() {
        val calls = mutableListOf<Boolean>()
        failure("usb_open_failed") { runUsbRecovery({ false }) { calls.add(it); -1 } }
        assertEquals(listOf(false), calls)
    }

    @Test fun cancellationAfterProbePreventsReset() {
        var cancelled = false
        val calls = mutableListOf<Boolean>()
        failure("usb_cancelled") {
            runUsbRecovery({ cancelled }) { calls.add(it); cancelled = true; 1 }
        }
        assertEquals(listOf(false), calls)
    }

    @Test fun cancellationAfterResetPreventsTransfer() {
        var cancelled = false
        failure("usb_cancelled") {
            runUsbRecovery({ cancelled }) { reset -> if (reset) { cancelled = true; 2 } else 1 }
        }
    }
}
