package ru.mkulkov.brizfi

import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class PickerImportBatchTest {
    private val parent = Files.createTempDirectory("brizfi-batch-test").toFile().canonicalFile
    private val storage = ManagedImportStorage(File(parent, "brizfi_imports"))
    private fun copy() = storage.importBook("book.epub", { ByteArrayInputStream(byteArrayOf(1)) }, { false })
    @After fun cleanup() { parent.deleteRecursively() }

    @Test fun laterCopyFailureRollsBackOnlyThisBatch() {
        val previous = copy()
        val original = File(parent, "original.epub").apply { writeText("original") }
        val batch = PickerImportBatch(storage)
        var copied: File? = null
        try {
            batch.copy(listOf("first", "second"), { if (it == "second") error("failure") else copy().also { file -> copied = file } }) { false }
            fail("Expected failure")
        } catch (_: IllegalStateException) { batch.rollback() }
        assertFalse(requireNotNull(copied).exists())
        assertTrue(previous.exists())
        assertEquals("original", original.readText())
        batch.rollback()
    }

    @Test fun teardownBeforeDeliveryRollsBackCompletedCopies() {
        val batch = PickerImportBatch(storage)
        val files = batch.copy(listOf("first", "second"), { copy() }) { false }
        batch.rollback()
        assertTrue(files.all { !it.exists() })
    }

    @Test fun teardownDuringCopyAndDeliveredCopiesHaveDifferentOwnership() {
        val abandoned = PickerImportBatch(storage)
        var file: File? = null
        var cancelled = false
        try {
            abandoned.copy(listOf("first"), { copy().also { file = it; cancelled = true } }) { cancelled }
            fail("Expected cancellation")
        } catch (error: ManagedImportStorage.Failure) { assertEquals("cancelled", error.code) }
        abandoned.rollback()
        assertFalse(requireNotNull(file).exists())
        val delivered = PickerImportBatch(storage)
        val kept = delivered.copy(listOf("first"), { copy() }) { false }
        delivered.delivered()
        delivered.rollback()
        assertTrue(kept.single().exists())
    }
}
