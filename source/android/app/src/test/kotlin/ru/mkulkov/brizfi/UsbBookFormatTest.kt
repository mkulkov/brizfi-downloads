package ru.mkulkov.brizfi

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Test

internal object UsbFormatFixtures {
    fun epub(extra: String? = null): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            val mime = "application/epub+zip".toByteArray()
            zip.putNextEntry(ZipEntry("mimetype").apply {
                method = ZipEntry.STORED; size = mime.size.toLong(); compressedSize = size
                crc = CRC32().apply { update(mime) }.value
            })
            zip.write(mime); zip.closeEntry()
            zip.putNextEntry(ZipEntry("META-INF/container.xml"))
            zip.write("<container/>".toByteArray()); zip.closeEntry()
            if (extra != null) { zip.putNextEntry(ZipEntry(extra)); zip.write("test".toByteArray()); zip.closeEntry() }
        }
        return output.toByteArray()
    }
}

class UsbBookFormatTest {
    private fun rejects(extension: String, bytes: ByteArray) {
        try { UsbBookFormat.validate(bytes, extension); fail("Expected invalid $extension") }
        catch (error: UsbTransferFailure) { assertEquals("usb_invalid_file", error.code) }
    }

    @Test fun epubGateChecksMimeCrcPathsAndEncryptionMetadata() {
        UsbBookFormat.validate(UsbFormatFixtures.epub(), "epub")
        for (name in listOf("../escape", "/absolute", "drive:path", "bad\\name", "META-INF/encryption.xml", "META-INF/rights.xml")) {
            rejects("epub", UsbFormatFixtures.epub(name))
        }
        rejects("epub", UsbFormatFixtures.epub().apply { this[38] = 0 })
        rejects("epub", "not a zip".toByteArray())
        rejects("epub", UsbFormatFixtures.epub().copyOf(20))
        rejects("epub", UsbFormatFixtures.epub().let { it.copyOf(it.size - 22) })
        rejects("mobi", UsbFormatFixtures.epub())
    }

    @Test fun pdfAndUtf8TextGatesRejectEncryptedOrBinaryInput() {
        UsbBookFormat.validate("%PDF-1.7\n1 0 obj <<>> endobj\n%%EOF".toByteArray(), "pdf")
        rejects("pdf", "%PDF-1.7\n/Encrypt 1 0 R\n%%EOF".toByteArray())
        rejects("pdf", "%PDF-1.7 truncated".toByteArray())
        rejects("pdf", "text only".toByteArray())
        UsbBookFormat.validate("UTF-8 текст\nwith tab\t".toByteArray(), "txt")
        rejects("txt", byteArrayOf(0))
        rejects("txt", byteArrayOf(0xc0.toByte(), 0xaf.toByte()))
        rejects("fb2", "<FictionBook/>".toByteArray())
        rejects("azw3", ByteArray(100))
    }

    @Test fun cancellationStopsFormatValidation() {
        try { UsbBookFormat.validate(UsbFormatFixtures.epub(), "epub") { true }; fail("Expected cancellation") }
        catch (error: UsbTransferFailure) { assertEquals("usb_cancelled", error.code) }
    }
}
