package ru.mkulkov.brizfi

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeNoException
import org.junit.Test

class UsbTransferCoreTest {
    private val parent = Files.createTempDirectory("brizfi-usb-test").toFile().canonicalFile
    private val root = File(parent, "brizfi_imports").apply { mkdir() }
    private var cancelled = false
    private val fixedId = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val phases = mutableListOf<String>()

    private fun managed(name: String = "book.azw3", count: Int = 140_000): File {
        val directory = File(root, UUID.randomUUID().toString()).apply { mkdir() }
        File(directory, ".brizfi_owned").writeText("brizfi-import-v1\n${directory.name}\n")
        return File(directory, name).apply { writeBytes(bytes(count)) }
    }

    private fun bytes(count: Int): ByteArray = ByteArray(count) { (it % 251).toByte() }.apply {
        if (count >= 110) {
            "BOOKMOBI".toByteArray(Charsets.US_ASCII).copyInto(this, 60)
            this[76] = 0; this[77] = 1
            this[78] = 0; this[79] = 0; this[80] = 0; this[81] = 86
            this[98] = 0; this[99] = 0
            "MOBI".toByteArray(Charsets.US_ASCII).copyInto(this, 102)
        }
    }

    private fun source(file: File = managed()) = UsbBookSource.inspect(root, file.path) { cancelled }
    private fun transfer(port: FakeMtp, file: File = managed()) =
        UsbTransferCore(port, { cancelled }, { phases.add(it) }, { fixedId }).transfer(source(file))
    private fun fails(code: String, action: () -> Unit) {
        try { action(); fail("Expected $code") }
        catch (error: UsbTransferFailure) { assertEquals(code, error.code) }
    }

    @After fun tearDown() { parent.deleteRecursively() }

    @Test fun sourceAcceptsManagedImportedAndConvertedAzw3AndHashesBytes() {
        for (name in listOf("book.AZW3", "source.epub.converted.azw3")) {
            val file = managed(name)
            val inspected = source(file)
            assertEquals(file.length(), inspected.bytes)
            assertArrayEquals(MessageDigest.getInstance("SHA-256").digest(file.readBytes()), inspected.digest)
        }
    }

    @Test fun profileAllowsOnlyItsNativeManagedFormats() {
        val pdf = managed("book.pdf").apply { writeBytes("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF".toByteArray()) }
        val epub = managed("book.epub").apply { writeBytes(UsbFormatFixtures.epub()) }
        assertEquals("pdf", UsbBookSource.inspect(root, pdf.path, UsbReaderProfile.NOOK) { false }.extension)
        assertEquals("epub", UsbBookSource.inspect(root, epub.path, UsbReaderProfile.NOOK) { false }.extension)
        fails("usb_invalid_file") { source(epub) }
        fails("usb_invalid_file") { UsbBookSource.inspect(root, managed().path, UsbReaderProfile.NOOK) { false } }
        val txt = managed("book.txt").apply { writeText("A short UTF-8 book\nТекст") }
        assertEquals("txt", source(txt).extension)
        fails("usb_invalid_file") { UsbBookSource.inspect(root, txt.path, UsbReaderProfile.NOOK) { false } }
    }

    @Test fun rawMtpPreservesEachKindleNativeExtension() {
        for (extension in listOf("mobi", "pdf", "txt")) {
            val file = managed("book.$extension")
            if (extension == "pdf") file.writeText("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF")
            if (extension == "txt") file.writeText("Local book text")
            assertEquals("brizfi-$fixedId.$extension", transfer(FakeMtp(), file).name)
        }
    }

    @Test fun outsideOriginalAndUnmarkedCopiesAreRejectedWithoutDeletion() {
        val outside = File(parent, "book.azw3").apply { writeBytes(bytes(100)) }
        fails("usb_invalid_file") { source(outside) }
        val file = managed()
        File(file.parentFile, ".brizfi_owned").delete()
        fails("usb_invalid_file") { source(file) }
        assertTrue(outside.exists())
        assertTrue(file.exists())
    }

    @Test fun relativeTraversalAndNestedPathsAreRejected() {
        val file = managed()
        val directory = requireNotNull(file.parentFile)
        fails("usb_invalid_file") { UsbBookSource.inspect(root, "relative.azw3") { false } }
        fails("usb_invalid_file") { source(File(directory, "../${directory.name}/${file.name}")) }
        val nested = File(directory, "nested").apply { mkdir() }
        val copy = File(nested, "book.azw3").apply { writeBytes(bytes(100)) }
        fails("usb_invalid_file") { source(copy) }
    }

    @Test fun invalidMarkerExtensionSignatureAndSizesAreRejected() {
        val markerFile = managed()
        File(markerFile.parentFile, ".brizfi_owned").writeText("wrong")
        fails("usb_invalid_file") { source(markerFile) }
        fails("usb_invalid_file") { source(managed("book.epub")) }
        val damaged = managed().apply { writeBytes(ByteArray(100)) }
        fails("usb_invalid_file") { source(damaged) }
        fails("usb_invalid_file") { source(managed(count = 68)) }
        val large = managed(count = 100)
        RandomAccessFile(large, "rw").use { it.setLength(UsbBookSource.MAX_BYTES + 1) }
        fails("usb_invalid_file") { source(large) }
    }

    @Test fun sourceSymlinkCannotAuthorizeReadingOutsideCopy() {
        val file = managed()
        val outside = File(parent, "outside.azw3").apply { writeBytes(bytes(100)) }
        file.delete()
        try { Files.createSymbolicLink(file.toPath(), outside.toPath()) }
        catch (error: Exception) { assumeNoException(error) }
        try {
            fails("usb_invalid_file") { source(file) }
            assertTrue(outside.exists())
        } finally { Files.deleteIfExists(file.toPath()) }
    }

    @Test fun cancelledSourceInspectionNeverStartsMtp() {
        cancelled = true
        fails("usb_cancelled") { source() }
    }

    @Test fun processLeaseBlocksAnotherControllerUntilWorkerReleasesSource() {
        val lease = UsbTransferLease()
        val first = managed()
        val second = managed()
        assertTrue(lease.claim(first.path))
        assertFalse(lease.claim(second.path))
        lease.release(second.path)
        assertFalse(lease.claim(second.path))
        lease.release(first.path)
        assertTrue(lease.claim(second.path))
    }

    @Test fun processLeaseProtectsEntireManagedSourceDirectoryOnly() {
        val lease = UsbTransferLease()
        val file = managed()
        val directory = requireNotNull(file.parentFile)
        assertTrue(lease.claim(file.path))
        assertTrue(lease.usesImport(file.path))
        assertTrue(lease.usesImport(directory.path))
        assertTrue(lease.usesImport(File(directory, "source.epub").path))
        assertFalse(lease.usesImport(managed().path))
        lease.release(file.path)
        assertFalse(lease.usesImport(file.path))
    }

    @Test fun cleanupAndNativeSourceClaimsCannotRaceAcrossControllers() {
        val lease = UsbTransferLease()
        val path = managed().path
        assertTrue(lease.claim(path))
        assertFalse(lease.collectIfIdle { fail("Cleanup cannot run during native reading") })
        lease.release(path)
        var collected = false
        assertTrue(lease.collectIfIdle {
            assertFalse(lease.claim(path))
            collected = true
        })
        assertTrue(collected)
        assertTrue(lease.claim(path))
    }

    @Test fun successfulTransferUsesDocumentsUniqueAsciiNameAndMatchingReadback() {
        val port = FakeMtp()
        val file = managed()
        val receipt = transfer(port, file)
        assertEquals(file.length(), receipt.bytes)
        assertEquals("brizfi-$fixedId.azw3", receipt.name)
        assertEquals(listOf("writing", "verifying"), phases)
        assertEquals(listOf(Pair(1, -1), Pair(1, 3)), port.queries)
        assertTrue(port.readLengths.all { it in 1..65536 })
        assertTrue(port.deleted.isEmpty())
        port.assertExistingPreserved()
    }

    @Test fun documentsNameIsCaseInsensitiveButMustBeUnprotectedRootFolder() {
        val port = FakeMtp()
        port.entries[3] = port.entries.getValue(3).copy(name = "DoCuMeNtS")
        transfer(port)
        val nested = FakeMtp()
        nested.entries[3] = nested.entries.getValue(3).copy(parent = 50)
        fails("usb_documents_missing") { transfer(nested) }
        val protected = FakeMtp()
        protected.entries[3] = protected.entries.getValue(3).copy(protection = 1)
        fails("usb_documents_missing") { transfer(protected) }
        assertEquals(0, nested.creates)
        assertEquals(0, protected.creates)
    }

    @Test fun missingDocumentsHasNoRootFallbackOrFolderCreation() {
        val port = FakeMtp()
        port.entries[3] = port.entries.getValue(3).copy(name = "books")
        fails("usb_documents_missing") { transfer(port) }
        assertEquals(0, port.creates)
        assertTrue(port.deleted.isEmpty())
    }

    @Test fun advertisedRequiredOperationsAndStorageSpaceAreCheckedBeforeCreate() {
        val noOperations = FakeMtp().apply { supportedOperations = null }
        fails("usb_unsupported") { transfer(noOperations) }
        val missingRead = FakeMtp().apply { supportedOperations = intArrayOf(0x100C, 0x100D) }
        fails("usb_unsupported") { transfer(missingRead) }
        val full = FakeMtp().apply { free = 0 }
        fails("usb_full") { transfer(full) }
        assertEquals(0, noOperations.creates + missingRead.creates + full.creates)
    }

    @Test fun excessiveStoragesOrObjectsAreRejectedBeforeWrite() {
        val storages = FakeMtp().apply { storageIds = IntArray(33) { it + 1 } }
        fails("usb_unsupported") { transfer(storages) }
        val objects = FakeMtp().apply { extraHandles = IntArray(4097) { it + 10 } }
        fails("usb_unsupported") { transfer(objects) }
        assertEquals(0, storages.creates + objects.creates)
    }

    @Test fun existingGeneratedNameIsNeverOverwritten() {
        val port = FakeMtp()
        port.entries[8] = port.entries.getValue(8).copy(name = "brizfi-$fixedId.azw3")
        fails("usb_transfer_failed") { transfer(port) }
        assertEquals(0, port.creates)
        port.assertExistingPreserved()
    }

    @Test fun failedSendRollsBackOnlyThisJobsNewObject() {
        val port = FakeMtp().apply { sendOk = false }
        fails("usb_transfer_failed") { transfer(port) }
        assertEquals(listOf(200), port.deleted)
        assertFalse(port.entries.containsKey(200))
        port.assertExistingPreserved()
    }

    @Test fun badDigestOrMetadataRollsBackNewObjectAndKeepsExistingBook() {
        val corrupt = FakeMtp().apply { corruptRead = true }
        fails("usb_verification_failed") { transfer(corrupt) }
        val metadata = FakeMtp().apply { wrongSize = true }
        fails("usb_verification_failed") { transfer(metadata) }
        assertEquals(listOf(200), corrupt.deleted)
        assertEquals(listOf(200), metadata.deleted)
        corrupt.assertExistingPreserved()
        metadata.assertExistingPreserved()
    }

    @Test fun zeroOversizedAndExcessivelyFragmentedReadbackAreBounded() {
        for (mode in 1..3) {
            val port = FakeMtp().apply { readMode = mode }
            fails("usb_verification_failed") { transfer(port) }
            assertTrue(port.readLengths.size <= 1024)
            assertEquals(listOf(200), port.deleted)
            port.assertExistingPreserved()
        }
    }

    @Test fun shorterPositiveChunksCanStillVerifyWithinBound() {
        val port = FakeMtp().apply { fragmentSize = 8192 }
        transfer(port)
        assertTrue(port.readLengths.size > 3)
    }

    @Test fun cancellationDuringSendOrReadWaitsForCallAndRollsBack() {
        val sending = FakeMtp().apply { afterSend = { cancelled = true } }
        fails("usb_cancelled") { transfer(sending) }
        assertEquals(listOf(200), sending.deleted)
        cancelled = false
        val reading = FakeMtp().apply { afterRead = { cancelled = true } }
        fails("usb_cancelled") { transfer(reading) }
        assertEquals(listOf(200), reading.deleted)
        sending.assertExistingPreserved()
        reading.assertExistingPreserved()
    }

    @Test fun failedOrDetachedRollbackReportsUncertain() {
        val port = FakeMtp().apply { sendOk = false; deleteOk = false }
        fails("usb_uncertain") { transfer(port) }
        assertTrue(port.entries.containsKey(200))
        port.assertExistingPreserved()
    }

    @Test fun noConfirmedCreationHandleCannotAuthorizeDeletingAnything() {
        val unknown = FakeMtp().apply { nullCreate = true }
        fails("usb_uncertain") { transfer(unknown) }
        val reused = FakeMtp().apply { reusedHandle = true }
        fails("usb_uncertain") { transfer(reused) }
        assertTrue(unknown.deleted.isEmpty())
        assertTrue(reused.deleted.isEmpty())
        reused.assertExistingPreserved()
    }

    @Test fun replacedRemoteIdentityCannotAuthorizeRollbackDeletion() {
        val port = FakeMtp().apply { sendOk = false; afterSend = {
            entries[200] = entries.getValue(200).copy(name = "other-users-book.azw3")
        } }
        fails("usb_uncertain") { transfer(port) }
        assertTrue(port.deleted.isEmpty())
        port.assertExistingPreserved()
    }

    private class FakeMtp : UsbMtpPort {
        val entries = mutableMapOf(
            3 to UsbMtpPort.ObjectInfo(3, 1, 0, UsbTransferCore.FOLDER, 0, "documents", 0),
            8 to UsbMtpPort.ObjectInfo(8, 1, 3, 0x3000, 0, "previous.azw3", 4),
        )
        private val oldBytes = byteArrayOf(1, 2, 3, 4)
        private val data = mutableMapOf(8 to oldBytes.copyOf())
        var supportedOperations: IntArray? = intArrayOf(0x100C, 0x100D, 0x101B)
        var storageIds = intArrayOf(1)
        var free = 40L * 1024 * 1024
        var extraHandles: IntArray? = null
        var creates = 0
        var sendOk = true
        var deleteOk = true
        var corruptRead = false
        var wrongSize = false
        var nullCreate = false
        var reusedHandle = false
        var readMode = 0
        var fragmentSize = 65536
        var afterSend: (() -> Unit)? = null
        var afterRead: (() -> Unit)? = null
        val deleted = mutableListOf<Int>()
        val queries = mutableListOf<Pair<Int, Int>>()
        val readLengths = mutableListOf<Int>()
        override fun operations() = supportedOperations
        override fun storages() = storageIds
        override fun freeBytes(storage: Int) = free
        override fun handles(storage: Int, parent: Int): IntArray {
            queries.add(storage to parent)
            return extraHandles ?: entries.values.filter { it.storage == storage &&
                it.parent == (if (parent == -1) 0 else parent) }.map { it.handle }.toIntArray()
        }
        override fun info(handle: Int) = entries[handle]
        override fun create(storage: Int, parent: Int, name: String, bytes: Long): UsbMtpPort.ObjectInfo? {
            creates++
            if (nullCreate) return null
            val created = UsbMtpPort.ObjectInfo(if (reusedHandle) 8 else 200, storage, parent, 0x3000, 0, name, bytes)
            if (!reusedHandle) entries[200] = created
            return created
        }
        override fun send(handle: Int, source: UsbBookSource.Source): Boolean {
            data[handle] = source.file.readBytes()
            if (wrongSize) entries[handle] = entries.getValue(handle).copy(bytes = source.bytes + 1)
            afterSend?.invoke()
            return sendOk
        }
        override fun read(handle: Int, offset: Long, length: Int, buffer: ByteArray): Long {
            readLengths.add(length)
            if (readMode == 1) return 0
            if (readMode == 2) return length + 1L
            val contents = data[handle] ?: throw IOException()
            val count = minOf(length, if (readMode == 3) 1 else fragmentSize, contents.size - offset.toInt())
            contents.copyInto(buffer, 0, offset.toInt(), offset.toInt() + count)
            if (corruptRead && count > 0) buffer[0] = (buffer[0].toInt() xor 1).toByte()
            afterRead?.invoke()
            return count.toLong()
        }
        override fun delete(handle: Int): Boolean {
            deleted.add(handle)
            if (deleteOk) { entries.remove(handle); data.remove(handle) }
            return deleteOk
        }
        fun assertExistingPreserved() {
            assertTrue(entries.containsKey(8))
            assertArrayEquals(oldBytes, data[8])
            assertFalse(deleted.contains(8))
            assertFalse(deleted.contains(3))
        }
    }
}
