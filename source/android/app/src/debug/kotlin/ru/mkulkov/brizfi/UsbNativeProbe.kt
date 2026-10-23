package ru.mkulkov.brizfi

import android.hardware.usb.UsbDeviceConnection
import android.os.ParcelFileDescriptor

/** Optional debug diagnostic. Recovery reset requires a separate explicit request. */
object UsbNativeProbe {
    init { System.loadLibrary("brizfi_usb_probe") }
    external fun probe(fd: Int): IntArray

    /** Separate connection, no queued Java requests; native receives its last fd. */
    fun probeAsync(connection: UsbDeviceConnection): IntArray {
        return owned(connection, ::asyncOwned)
    }

    fun probeRecovery(connection: UsbDeviceConnection): IntArray {
        return owned(connection, ::recoveryOwned)
    }

    private fun owned(connection: UsbDeviceConnection, operation: (Int) -> IntArray): IntArray {
        return ParcelFileDescriptor.fromFd(connection.fileDescriptor).use { duplicate ->
            connection.close()
            val owned = duplicate.detachFd()
            try {
                operation(owned)
            } catch (error: UnsatisfiedLinkError) {
                // Native never entered. Other exceptions may follow native close.
                ParcelFileDescriptor.adoptFd(owned).close()
                throw error
            }
        }
    }

    private external fun asyncOwned(fd: Int): IntArray
    private external fun recoveryOwned(fd: Int): IntArray
}
