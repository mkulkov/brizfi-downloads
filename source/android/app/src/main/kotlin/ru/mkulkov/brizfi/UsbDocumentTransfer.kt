package ru.mkulkov.brizfi

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

/** A user-authorized directory; IDs are opaque provider document IDs, never file paths. */
internal interface UsbDocumentPort {
    data class Document(
        val id: String,
        val name: String,
        val bytes: Long?,
        val directory: Boolean = false,
        val canCreate: Boolean = false,
        val canWrite: Boolean = false,
        val canDelete: Boolean = false,
    )

    interface WriteHandle : AutoCloseable {
        val output: OutputStream
        /** Must commit provider data and propagate errors, not just flush a Java buffer. */
        fun sync()
    }

    fun folder(): Document
    fun children(): List<Document>
    fun info(id: String): Document?
    fun create(name: String): Document?
    fun openWrite(id: String): WriteHandle
    fun openRead(id: String): InputStream
    fun delete(id: String): Boolean
}

/** Synchronous worker-only copy. The caller keeps the inspected source leased until this returns. */
internal class UsbDocumentTransfer(
    private val port: UsbDocumentPort,
    private val cancelled: () -> Boolean,
    private val phase: (String) -> Unit,
    private val profile: UsbReaderProfile = UsbReaderProfile.KINDLE,
    private val newId: () -> UUID = UUID::randomUUID,
) {
    fun transfer(source: UsbBookSource.Source): UsbTransferCore.Receipt {
        var creationStarted = false
        var own: UsbDocumentPort.Document? = null
        try {
            checkCancelled()
            if (source.bytes !in 1..UsbBookSource.MAX_BYTES || source.extension !in profile.formats || source.digest.size != 32 ||
                !source.file.isFile || source.file.length() != source.bytes
            ) fail("usb_invalid_file")
            val folder = port.folder()
            if (!folder.directory || !folder.canCreate || folder.id.isEmpty() || !UsbSafFolderPolicy.folderName(profile, folder.name)) fail("usb_unsupported")
            val before = children()
            val existing = before.map { it.id }.toSet() + folder.id
            val name = (1..3).map { "brizfi-${newId()}.${source.extension}" }.firstOrNull { candidate ->
                before.none { it.name.equals(candidate, ignoreCase = true) }
            } ?: fail("usb_transfer_failed")
            checkCancelled()
            phase("writing")
            checkCancelled()
            creationStarted = true
            val created = port.create(name) ?: fail("usb_uncertain")
            // A returned URI alone cannot authorize opening or deleting a pre-existing book.
            if (created.id.isEmpty() || created.id in existing || created.name != name || created.directory) {
                fail("usb_uncertain")
            }
            own = created
            val initial = identity(created) ?: fail("usb_uncertain")
            if (!initial.canWrite || !initial.canDelete || initial.bytes != 0L) fail("usb_unsupported")
            checkCancelled()
            val copied = MessageDigest.getInstance("SHA-256")
            source.file.inputStream().use { input ->
                port.openWrite(created.id).use { writer ->
                    copy(input, source.bytes, copied) { buffer, count -> writer.output.write(buffer, 0, count) }
                    if (!MessageDigest.isEqual(copied.digest(), source.digest)) fail("usb_invalid_file")
                    checkCancelled()
                    writer.sync()
                }
            }
            // AutoCloseOutputStream closes the write FD before any query/read of the result.
            checkCancelled()
            phase("verifying")
            val actual = identity(created) ?: fail("usb_verification_failed")
            if (actual.bytes != source.bytes) fail("usb_verification_failed")
            val readback = MessageDigest.getInstance("SHA-256")
            port.openRead(created.id).use { input -> copy(input, source.bytes, readback) { _, _ -> } }
            if (!MessageDigest.isEqual(readback.digest(), source.digest)) fail("usb_verification_failed")
            checkCancelled()
            // Recheck identity/size after the read; concurrent edits must not produce success.
            if (identity(created)?.bytes != source.bytes) fail("usb_verification_failed")
            checkCancelled()
            return UsbTransferCore.Receipt(source.bytes, name)
        } catch (error: Exception) {
            val original = when (error) {
                is UsbTransferFailure -> error.code
                is SecurityException -> "usb_permission"
                else -> "usb_transfer_failed"
            }
            if (creationStarted && (own == null || !cleanup(own))) fail("usb_uncertain")
            fail(original)
        }
    }

    private fun copy(
        input: InputStream,
        expected: Long,
        digest: MessageDigest,
        accept: (ByteArray, Int) -> Unit,
    ) {
        val buffer = ByteArray(CHUNK)
        var count = 0L
        var reads = 0
        while (true) {
            checkCancelled()
            // Bound pathological streams that return one byte or zero forever.
            if (++reads > MAX_READS) fail("usb_transfer_failed")
            val length = input.read(buffer)
            if (length < 0) break
            if (length == 0 || length > buffer.size) fail("usb_transfer_failed")
            count += length
            if (count > expected || count > UsbBookSource.MAX_BYTES) fail("usb_verification_failed")
            digest.update(buffer, 0, length)
            accept(buffer, length)
        }
        if (count != expected) fail("usb_verification_failed")
    }

    private fun children(): List<UsbDocumentPort.Document> {
        val result = port.children()
        if (result.size > MAX_CHILDREN || result.any { it.id.isEmpty() } ||
            result.map { it.id }.toSet().size != result.size
        ) fail("usb_unsupported")
        return result
    }

    /** Both a fresh direct-child listing and an independent query must identify our UUID name. */
    private fun identity(own: UsbDocumentPort.Document): UsbDocumentPort.Document? {
        val listed = children().singleOrNull { it.id == own.id } ?: return null
        val actual = port.info(own.id) ?: return null
        if (listed.name != own.name || listed.directory || actual.id != own.id ||
            actual.name != own.name || actual.directory || listed.bytes != actual.bytes
        ) return null
        return actual
    }

    private fun cleanup(own: UsbDocumentPort.Document): Boolean = runCatching {
        val current = identity(own) ?: return@runCatching false
        if (!current.canDelete || !port.delete(own.id)) return@runCatching false
        children().none { it.id == own.id }
    }.getOrDefault(false)

    private fun checkCancelled() { if (cancelled()) fail("usb_cancelled") }
    private fun fail(code: String): Nothing = throw UsbTransferFailure(code)

    companion object {
        internal const val CHUNK = 64 * 1024
        internal const val MAX_CHILDREN = 4096
        private const val MAX_READS = 65536
    }
}
