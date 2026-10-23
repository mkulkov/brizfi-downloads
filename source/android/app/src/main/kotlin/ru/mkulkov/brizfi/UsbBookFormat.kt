package ru.mkulkov.brizfi

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

/** Bounded native format gates, not a promise that every document will render. */
internal object UsbBookFormat {
    fun validate(bytes: ByteArray, extension: String, cancelled: () -> Boolean = { false }) {
        fun invalid(): Nothing = throw UsbTransferFailure("usb_invalid_file")
        if (bytes.isEmpty() || bytes.size > UsbBookSource.MAX_BYTES) invalid()
        if (cancelled()) throw UsbTransferFailure("usb_cancelled")
        when (extension) {
            "epub" -> epub(bytes, cancelled)
            "azw3", "mobi" -> {
                if (bytes.size < 86 || String(bytes, 60, 8, Charsets.US_ASCII) != "BOOKMOBI") invalid()
                val records = ((bytes[76].toInt() and 255) shl 8) or (bytes[77].toInt() and 255)
                if (records !in 1..4096 || 78L + records * 8L > bytes.size) invalid()
                var previous = 0L
                repeat(records) { index ->
                    val record = be32(bytes, 78 + index * 8)
                    if (record < 78L + records * 8L || record >= bytes.size || (index > 0 && record < previous)) invalid()
                    previous = record
                }
                val start = be32(bytes, 78)
                if (start + 24 > bytes.size) invalid()
                val record = start.toInt()
                if (String(bytes, record + 16, 4, Charsets.US_ASCII) != "MOBI" ||
                    bytes[record + 12] != 0.toByte() || bytes[record + 13] != 0.toByte()) invalid()
            }
            "pdf" -> {
                val prefix = String(bytes, 0, minOf(1024, bytes.size), Charsets.ISO_8859_1)
                val suffix = String(bytes, maxOf(0, bytes.size - 1024), minOf(1024, bytes.size), Charsets.ISO_8859_1)
                if (!prefix.contains("%PDF-") || !suffix.contains("%%EOF") ||
                    String(bytes, Charsets.ISO_8859_1).contains("/Encrypt")) invalid()
            }
            "txt" -> {
                if (bytes.any { (it.toInt() and 255).let { value -> value < 32 && value != 9 && value != 10 && value != 13 || value == 127 } }) invalid()
                try {
                    Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes))
                } catch (_: Exception) { invalid() }
            }
            else -> invalid()
        }
    }

    private fun be32(bytes: ByteArray, offset: Int): Long = (0..3).fold(0L) { value, index ->
        (value shl 8) or (bytes[offset + index].toLong() and 255)
    }

    private fun le16(bytes: ByteArray, offset: Int): Int {
        if (offset < 0 || offset.toLong() + 2 > bytes.size) throw UsbTransferFailure("usb_invalid_file")
        return (bytes[offset].toInt() and 255) or ((bytes[offset + 1].toInt() and 255) shl 8)
    }
    private fun le32(bytes: ByteArray, offset: Int): Long =
        le16(bytes, offset).toLong() or (le16(bytes, offset + 2).toLong() shl 16)

    private fun zipDirectory(bytes: ByteArray): Set<String> {
        fun invalid(): Nothing = throw UsbTransferFailure("usb_invalid_file")
        if (bytes.size < 22 || le32(bytes, 0) != 0x04034b50L) invalid()
        var end = bytes.size - 22
        val minimum = maxOf(0, bytes.size - 65557)
        while (le32(bytes, end) != 0x06054b50L || end.toLong() + 22 + le16(bytes, end + 20) != bytes.size.toLong()) {
            if (end == minimum) invalid()
            end--
        }
        val entries = le16(bytes, end + 10)
        var offset = le32(bytes, end + 16)
        if (entries !in 1..4096 || le16(bytes, end + 4) != 0 || le16(bytes, end + 6) != 0 ||
            entries != le16(bytes, end + 8) || offset > end || le32(bytes, end + 12) != end - offset) invalid()
        val names = mutableSetOf<String>()
        var expanded = 0L
        repeat(entries) {
            if (offset + 46 > end || le32(bytes, offset.toInt()) != 0x02014b50L) invalid()
            val at = offset.toInt()
            val nameLength = le16(bytes, at + 28)
            val length = 46L + nameLength + le16(bytes, at + 30) + le16(bytes, at + 32)
            expanded += le32(bytes, at + 24)
            if (offset + length > end || le16(bytes, at + 34) != 0 || (le16(bytes, at + 8) and 1) != 0 ||
                le16(bytes, at + 10) !in listOf(0, 8) || expanded > 128L * 1024 * 1024) invalid()
            val name = String(bytes, at + 46, nameLength, Charsets.UTF_8)
            if (!names.add(name)) invalid()
            offset += length
        }
        if (offset != end.toLong()) invalid()
        return names
    }

    private fun epub(bytes: ByteArray, cancelled: () -> Boolean) {
        fun invalid(): Nothing = throw UsbTransferFailure("usb_invalid_file")
        val centralNames = zipDirectory(bytes)
        var expanded = 0L
        val names = mutableSetOf<String>()
        var container = false
        try {
            ZipInputStream(ByteArrayInputStream(bytes)).use { input ->
                var entries = 0
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    if (cancelled()) throw UsbTransferFailure("usb_cancelled")
                    val entry = input.nextEntry ?: break
                    if (++entries > 4096) invalid()
                    val name = entry.name
                    if (!names.add(name) || name.isEmpty() || name.startsWith('/') || '\\' in name || ':' in name ||
                        '\u0000' in name || name.split('/').any { it == ".." } ||
                        name == "META-INF/encryption.xml" || name == "META-INF/rights.xml") invalid()
                    if (entries == 1 && (name != "mimetype" || entry.method != ZipEntry.STORED || entry.size != 20L)) invalid()
                    if (name == "META-INF/container.xml" && !entry.isDirectory) container = true
                    var length = 0L
                    while (true) {
                        if (cancelled()) throw UsbTransferFailure("usb_cancelled")
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count == 0) invalid()
                        length += count
                        expanded += count
                        if (expanded > 128L * 1024 * 1024) invalid()
                        if (entries == 1 && (length > 20 || count != 20 ||
                            String(buffer, 0, count, Charsets.US_ASCII) != "application/epub+zip")) invalid()
                    }
                    if (entries == 1 && length != 20L) invalid()
                    input.closeEntry() // ZipInputStream verifies CRC while reaching EOF.
                }
                if (entries == 0 || !container || names != centralNames) invalid()
            }
        } catch (error: UsbTransferFailure) { throw error }
        catch (_: Exception) { invalid() }
    }
}
