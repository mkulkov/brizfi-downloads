package ru.mkulkov.brizfi

/** Runs before opening MTP, never retries a failed reset or a file operation. */
internal fun runUsbRecovery(cancelled: () -> Boolean, check: (Boolean) -> Int): Int {
    fun ensureActive() { if (cancelled()) throw UsbTransferFailure("usb_cancelled") }
    ensureActive()
    val initial = check(false)
    ensureActive()
    val result = if (initial == 1) check(true) else initial
    ensureActive()
    when (result) {
        0, 2 -> return result
        -2 -> throw UsbTransferFailure("usb_busy")
        else -> throw UsbTransferFailure("usb_open_failed")
    }
}
