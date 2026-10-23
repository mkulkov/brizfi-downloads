package ru.mkulkov.brizfi

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class UsbDocumentTransferTest {
    private val uuid = UUID.fromString("12345678-1234-1234-1234-123456789abc")
    private val name = "brizfi-$uuid.azw3"

    private class FakePort : UsbDocumentPort {
        val documents = linkedMapOf<String, UsbDocumentPort.Document>()
        val events = mutableListOf<String>()
        val deleted = mutableListOf<String>()
        var folder = UsbDocumentPort.Document("folder", "documents", null, true, true)
        var created: UsbDocumentPort.Document? = null
        var payload = byteArrayOf()
        var readback: ByteArray? = null
        var readFactory: (() -> InputStream)? = null
        var createResult: ((String) -> UsbDocumentPort.Document?)? = null
        var afterCreate: (() -> Unit)? = null
        var afterWrite: (() -> Unit)? = null
        var afterClose: (() -> Unit)? = null
        var afterRead: (() -> Unit)? = null
        var childResult: (() -> List<UsbDocumentPort.Document>)? = null
        var infoResult: ((String) -> UsbDocumentPort.Document?)? = null
        var failWrite = false
        var failSync = false
        var failClose = false
        var failDelete = false
        var leaveAfterDelete = false
        var writeOpen = false
        var largestWrite = 0
        var readLimit = Int.MAX_VALUE

        override fun folder() = folder
        override fun children() = childResult?.invoke() ?: documents.values.toList()
        override fun info(id: String) = infoResult?.invoke(id) ?: documents[id]
        override fun create(name: String): UsbDocumentPort.Document? {
            events.add("create")
            val result = if (createResult != null) createResult!!.invoke(name) else {
                UsbDocumentPort.Document("new", name, 0, canWrite = true, canDelete = true)
                    .also { documents[it.id] = it }
            }
            created = result
            afterCreate?.invoke()
            return result
        }

        override fun openWrite(id: String): UsbDocumentPort.WriteHandle {
            events.add("open-write:$id")
            writeOpen = true
            val data = ByteArrayOutputStream()
            return object : UsbDocumentPort.WriteHandle {
                override val output = object : OutputStream() {
                    override fun write(value: Int) { throw AssertionError("Use bounded chunks") }
                    override fun write(buffer: ByteArray, offset: Int, length: Int) {
                        largestWrite = maxOf(largestWrite, length)
                        if (failWrite) throw java.io.IOException("write")
                        data.write(buffer, offset, length)
                        afterWrite?.invoke()
                    }
                }
                override fun sync() {
                    events.add("sync")
                    if (failSync) throw java.io.IOException("sync")
                    payload = data.toByteArray()
                    documents[id] = documents.getValue(id).copy(bytes = payload.size.toLong())
                }
                override fun close() {
                    events.add("close-write")
                    writeOpen = false
                    afterClose?.invoke()
                    if (failClose) throw java.io.IOException("close")
                }
            }
        }

        override fun openRead(id: String): InputStream {
            assertFalse("The write descriptor must close before verification", writeOpen)
            events.add("open-read:$id")
            val input = readFactory?.invoke() ?: object : ByteArrayInputStream(readback ?: payload) {
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                    super.read(buffer, offset, minOf(length, readLimit))
            }
            return object : InputStream() {
                override fun read() = input.read()
                override fun read(buffer: ByteArray, offset: Int, length: Int) = input.read(buffer, offset, length)
                override fun close() { input.close(); events.add("close-read"); afterRead?.invoke() }
            }
        }

        override fun delete(id: String): Boolean {
            assertFalse("Cleanup must wait for the write descriptor", writeOpen)
            events.add("delete:$id")
            deleted.add(id)
            if (failDelete) return false
            if (!leaveAfterDelete) documents.remove(id)
            return true
        }
    }

    private fun source(size: Int = 200): UsbBookSource.Source {
        val bytes = ByteArray(size) { (it * 31).toByte() }
        "BOOKMOBI".toByteArray().copyInto(bytes, 60)
        val file = Files.createTempFile("brizfi-doc-test", ".azw3").toFile()
        file.deleteOnExit()
        file.writeBytes(bytes)
        return UsbBookSource.Source(file, size.toLong(), MessageDigest.getInstance("SHA-256").digest(bytes))
    }

    private fun transfer(
        port: FakePort,
        source: UsbBookSource.Source = source(),
        cancelled: () -> Boolean = { false },
        phase: (String) -> Unit = {},
    ) = UsbDocumentTransfer(port, cancelled, phase) { uuid }.transfer(source)

    private fun failure(code: String, block: () -> Unit) {
        try { block(); fail("Expected $code") }
        catch (error: UsbTransferFailure) { assertEquals(code, error.code) }
    }

    @Test fun copiesCommitsClosesAndVerifiesAllBytes() {
        val port = FakePort()
        val source = source(150000)
        val phases = mutableListOf<String>()
        val receipt = transfer(port, source, phase = phases::add)
        assertEquals(UsbTransferCore.Receipt(source.bytes, name), receipt)
        assertArrayEquals(source.file.readBytes(), port.payload)
        assertEquals(listOf("writing", "verifying"), phases)
        assertEquals(listOf("create", "open-write:new", "sync", "close-write", "open-read:new", "close-read"), port.events)
        assertEquals(65536, port.largestWrite)
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun nookCopiesNativeEpubAndPdfWithOriginalExtension() {
        for (extension in listOf("epub", "pdf")) {
            val file = Files.createTempFile("brizfi-nook-doc", ".$extension").toFile()
            try {
                val bytes = if (extension == "epub") UsbFormatFixtures.epub() else "%PDF-1.4\n%%EOF".toByteArray()
                file.writeBytes(bytes)
                val source = UsbBookSource.Source(file, bytes.size.toLong(), MessageDigest.getInstance("SHA-256").digest(bytes))
                val port = FakePort().apply { folder = folder.copy(name = "Books") }
                val receipt = UsbDocumentTransfer(port, { false }, {}, UsbReaderProfile.NOOK) { uuid }.transfer(source)
                assertEquals("brizfi-$uuid.$extension", receipt.name)
                assertArrayEquals(bytes, port.payload)
                assertTrue(port.deleted.isEmpty())
            } finally { file.delete() }
        }
    }

    @Test fun nookRejectsWrongFolderAndKindleSourceBeforeCreation() {
        val wrongFolder = FakePort()
        val pdf = source().let { original ->
            val file = Files.createTempFile("brizfi-nook-doc", ".pdf").toFile().apply { writeText("%PDF-1.4\n%%EOF"); deleteOnExit() }
            UsbBookSource.Source(file, file.length(), MessageDigest.getInstance("SHA-256").digest(file.readBytes()))
        }
        failure("usb_unsupported") { UsbDocumentTransfer(wrongFolder, { false }, {}, UsbReaderProfile.NOOK).transfer(pdf) }
        assertTrue(wrongFolder.events.isEmpty())
        val wrongFormat = FakePort().apply { folder = folder.copy(name = "Books") }
        failure("usb_invalid_file") { UsbDocumentTransfer(wrongFormat, { false }, {}, UsbReaderProfile.NOOK).transfer(source()) }
        assertTrue(wrongFormat.events.isEmpty())
    }

    @Test fun acceptsShortReadbackChunks() {
        val port = FakePort().apply { readLimit = 7 }
        assertEquals(200, transfer(port).bytes)
    }

    @Test fun existingBookNeverOpenedOrDeleted() {
        val port = FakePort()
        port.documents["old"] = UsbDocumentPort.Document("old", "user.azw3", 123, canWrite = true, canDelete = true)
        transfer(port)
        assertTrue(port.documents.containsKey("old"))
        assertTrue(port.events.none { it.endsWith(":old") })
    }

    @Test fun rejectsReadOnlyFolderBeforeCreation() {
        val port = FakePort().apply { folder = folder.copy(canCreate = false) }
        failure("usb_unsupported") { transfer(port) }
        assertTrue(port.events.isEmpty())
    }

    @Test fun rejectsOversizeSourceBeforeCreation() {
        val port = FakePort()
        val source = source().copy(bytes = UsbBookSource.MAX_BYTES + 1)
        failure("usb_invalid_file") { transfer(port, source) }
        assertTrue(port.events.isEmpty())
    }

    @Test fun cancellationBeforeCreationDoesNotCreate() {
        val port = FakePort()
        failure("usb_cancelled") { transfer(port, cancelled = { true }) }
        assertTrue(port.events.isEmpty())
    }

    @Test fun cancellationFromWritingPhaseDoesNotCreate() {
        var cancel = false
        val port = FakePort()
        failure("usb_cancelled") {
            transfer(port, cancelled = { cancel }, phase = { cancel = true })
        }
        assertTrue(port.events.isEmpty())
    }

    @Test fun cancellationDuringFinalIdentityQueryDoesNotReturnReceipt() {
        var cancel = false
        var queries = 0
        val port = FakePort()
        port.infoResult = { id ->
            if (++queries == 3) cancel = true
            port.documents[id]
        }
        failure("usb_cancelled") { transfer(port, cancelled = { cancel }) }
        assertEquals(listOf("new"), port.deleted)
    }

    @Test fun cancellationAfterCreationCleansOnlyOwnChild() {
        var cancel = false
        val port = FakePort().apply { afterCreate = { cancel = true } }
        failure("usb_cancelled") { transfer(port, cancelled = { cancel }) }
        assertEquals(listOf("new"), port.deleted)
        assertFalse(port.events.any { it.startsWith("open-write") })
    }

    @Test fun cancellationDuringCopyClosesBeforeCleanup() {
        var cancel = false
        val port = FakePort().apply { afterWrite = { cancel = true } }
        failure("usb_cancelled") { transfer(port, source(100000), { cancel }) }
        assertEquals(listOf("create", "open-write:new", "close-write", "delete:new"), port.events)
    }

    @Test fun writeFailureClosesBeforeCleanupAndPreservesSource() {
        val port = FakePort().apply { failWrite = true }
        val source = source()
        val original = source.file.readBytes()
        failure("usb_transfer_failed") { transfer(port, source) }
        assertEquals(listOf("create", "open-write:new", "close-write", "delete:new"), port.events)
        assertArrayEquals(original, source.file.readBytes())
    }

    @Test fun syncFailureIsNotSuccessfulClose() {
        val port = FakePort().apply { failSync = true }
        failure("usb_transfer_failed") { transfer(port) }
        assertEquals(listOf("create", "open-write:new", "sync", "close-write", "delete:new"), port.events)
    }

    @Test fun closeFailureDoesNotStartReadback() {
        val port = FakePort().apply { failClose = true }
        failure("usb_transfer_failed") { transfer(port) }
        assertTrue(port.events.none { it.startsWith("open-read") })
        assertEquals(listOf("new"), port.deleted)
    }

    @Test fun sourceDigestChangeCleansOwnedPlaceholder() {
        val port = FakePort()
        val source = source()
        val altered = source.file.readBytes().apply { this[0] = (this[0] + 1).toByte() }
        source.file.writeBytes(altered)
        failure("usb_invalid_file") { transfer(port, source) }
        assertEquals(listOf("new"), port.deleted)
        assertTrue(port.events.none { it == "sync" })
    }

    @Test fun wrongReadbackHashCleansOnlyOwnedChild() {
        val source = source()
        val port = FakePort().apply { readback = source.file.readBytes().apply { this[0] = 33 } }
        failure("usb_verification_failed") { transfer(port, source) }
        assertTrue(port.events.indexOf("close-read") < port.events.indexOf("delete:new"))
    }

    @Test fun shortReadbackIsRejected() {
        val port = FakePort().apply { readback = ByteArray(199) }
        failure("usb_verification_failed") { transfer(port) }
        assertEquals(listOf("new"), port.deleted)
    }

    @Test fun extraReadbackByteIsRejected() {
        val source = source()
        val port = FakePort().apply { readback = source.file.readBytes() + byteArrayOf(0) }
        failure("usb_verification_failed") { transfer(port, source) }
    }

    @Test fun zeroLengthNonEofReadIsBoundedFailure() {
        val port = FakePort().apply {
            readFactory = { object : InputStream() {
                override fun read() = 0
                override fun read(buffer: ByteArray, offset: Int, length: Int) = 0
            } }
        }
        failure("usb_transfer_failed") { transfer(port) }
        assertEquals(listOf("new"), port.deleted)
    }

    @Test fun nullCreationIsUncertainAndCannotDeleteAnything() {
        val port = FakePort().apply { createResult = { null } }
        failure("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun creationExceptionIsUncertain() {
        val port = FakePort().apply { createResult = { throw java.io.IOException() } }
        failure("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun reusedCreationIdNeverOpensOrDeletesForeignBook() {
        val port = FakePort()
        val old = UsbDocumentPort.Document("old", name, 0, canWrite = true, canDelete = true)
        port.documents["old"] = old.copy(name = "user.azw3")
        port.createResult = { old }
        failure("usb_uncertain") { transfer(port) }
        assertEquals(listOf("create"), port.events)
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun renamedCreationCannotAuthorizeDeletion() {
        val port = FakePort().apply {
            createResult = { UsbDocumentPort.Document("new", "user.azw3", 0, canWrite = true, canDelete = true) }
        }
        failure("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun creationOutsideSelectedParentIsUncertain() {
        val port = FakePort().apply {
            createResult = { UsbDocumentPort.Document("new", it, 0, canWrite = true, canDelete = true) }
        }
        failure("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
        assertEquals(listOf("create"), port.events)
    }

    @Test fun concurrentRenamePreventsCleanupDeletion() {
        val port = FakePort().apply {
            afterClose = { documents["new"] = documents.getValue("new").copy(name = "user.azw3") }
        }
        failure("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun changedSizeAfterReadPreventsSuccessfulReceipt() {
        val port = FakePort().apply {
            afterRead = { documents["new"] = documents.getValue("new").copy(bytes = 199) }
        }
        failure("usb_verification_failed") { transfer(port) }
        assertEquals(listOf("new"), port.deleted)
    }

    @Test fun failedCleanupReportsUncertainty() {
        val port = FakePort().apply { failSync = true; failDelete = true }
        failure("usb_uncertain") { transfer(port) }
    }

    @Test fun deletionMustBeConfirmedByFreshListing() {
        val port = FakePort().apply { failSync = true; leaveAfterDelete = true }
        failure("usb_uncertain") { transfer(port) }
    }

    @Test fun initialNonzeroSizeIsRejectedAndOnlyOwnFileCleaned() {
        val port = FakePort().apply {
            afterCreate = { documents["new"] = documents.getValue("new").copy(bytes = 1) }
        }
        failure("usb_unsupported") { transfer(port) }
        assertEquals(listOf("new"), port.deleted)
        assertTrue(port.events.none { it.startsWith("open-write") })
    }

    @Test fun duplicateChildIdsAreRejectedBeforeCreation() {
        val port = FakePort().apply {
            childResult = { listOf(folder, folder) }
        }
        failure("usb_unsupported") { transfer(port) }
        assertTrue(port.events.isEmpty())
    }

    @Test fun childListingIsBounded() {
        val port = FakePort().apply {
            childResult = { (0..UsbDocumentTransfer.MAX_CHILDREN).map { folder.copy(id = "id$it") } }
        }
        failure("usb_unsupported") { transfer(port) }
        assertTrue(port.events.isEmpty())
    }

    @Test fun nameCollisionDoesNotOpenOrOverwriteExistingFile() {
        val port = FakePort()
        port.documents["old"] = UsbDocumentPort.Document("old", name.uppercase(), 200)
        failure("usb_transfer_failed") { transfer(port) }
        assertTrue(port.events.isEmpty())
        assertTrue(port.documents.containsKey("old"))
    }
}
