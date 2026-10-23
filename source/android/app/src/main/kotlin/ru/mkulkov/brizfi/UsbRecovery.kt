package ru.mkulkov.brizfi

import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager

/** Android preflight limited to the verified Kindle USB interface, not phone model. */
internal object UsbRecovery {
    private val available = try {
        System.loadLibrary("brizfi_usb_recovery")
        true
    } catch (_: UnsatisfiedLinkError) { false }

    fun applies(device: UsbDevice): Boolean =
        device.vendorId == 0x1949 && device.productId == 0x9981 &&
        device.configurationCount == 1 && device.interfaceCount == 1 &&
        device.getInterface(0).let {
            it.id == 0 && it.alternateSetting == 0 && it.interfaceClass == 255 &&
                it.interfaceSubclass == 255 && it.interfaceProtocol == 0
        }

    fun prepare(manager: UsbManager, device: UsbDevice, cancelled: () -> Boolean): Int {
        if (!available) throw UsbTransferFailure("usb_open_failed")
        val connection = manager.openDevice(device) ?: throw UsbTransferFailure("usb_permission")
        try {
            return runUsbRecovery(cancelled) { reset -> nativeCheck(connection.fileDescriptor, reset) }
        } finally { connection.close() }
    }

    private external fun nativeCheck(fd: Int, reset: Boolean): Int
}
