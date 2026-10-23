package ru.mkulkov.brizfi

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.ArrayDeque
import org.junit.Assert.*
import org.junit.Test

class UsbBulkMtpPortTest {
    private class FakeIo(
        override val packetSize: Int = 64,
        var readLimit: Int = 16384,
        var writeLimit: Int = 16384,
    ) : MtpBulkIo {
        private val chunks = ArrayDeque<ByteArray>()
        private var offset = 0
        val written = ByteArrayOutputStream()
        val writeSizes = mutableListOf<Int>()
        var closed = false
        var reads = 0
        var readResult: Int? = null
        var writeResult: Int? = null
        var afterWrite: (() -> Unit)? = null
        fun enqueue(vararg bytes: ByteArray) { bytes.forEach { chunks.add(it) } }
        override fun read(buffer: ByteArray, timeoutMs: Int): Int {
            assertTrue(timeoutMs in 1..1000)
            assertEquals(16384, buffer.size) // Never request only the 12-byte container header.
            reads++
            readResult?.let { return it }
            if (chunks.isEmpty()) return -1
            val current = chunks.first()
            val count = minOf(buffer.size, readLimit, current.size - offset)
            current.copyInto(buffer, 0, offset, offset + count)
            offset += count
            if (offset == current.size) { chunks.removeFirst(); offset = 0 }
            return count
        }
        override fun write(buffer: ByteArray, offset: Int, length: Int, timeoutMs: Int): Int {
            assertTrue(timeoutMs in 1..1000)
            writeResult?.let { return it }
            val count = minOf(writeLimit, length)
            written.write(buffer, offset, count)
            writeSizes.add(count)
            afterWrite?.invoke()
            return count
        }
        override fun close() { closed = true }
    }

    private fun frame(type: Int, code: Int, transaction: Int, payload: ByteArray = byteArrayOf()) =
        MtpBulkProtocol.container(type, code, transaction, payload)
    private fun dataset(block: MtpDatasetWriter.() -> Unit) = MtpDatasetWriter().apply(block).bytes()
    private fun parameters(vararg values: Long) = dataset { values.forEach(::u32) }
    private fun response(transaction: Int, code: Int = 0x2001, vararg values: Long) =
        frame(3, code, transaction, parameters(*values))
    private fun fails(code: String? = null, block: () -> Unit) {
        try { block(); fail("Expected failure") }
        catch (failure: UsbTransferFailure) { if (code != null) assertEquals(code, failure.code) }
    }
    private fun session(io: FakeIo, cancelled: () -> Boolean = { false }) =
        MtpBulkProtocol(io, cancelled).apply { beginSession() }

    @Test fun combinedContainersAndPartialUsbReadsAndWritesPreserveBytes() {
        val payload = ByteArray(20000) { (it % 251).toByte() }
        val io = FakeIo(readLimit = 37, writeLimit = 7)
        io.enqueue(frame(2, 0x101B, 1, payload) + response(1, 0x2001, payload.size.toLong()))
        val result = session(io).exchange(0x101B, intArrayOf(42, 0, payload.size))
        assertArrayEquals(payload, result.data)
        assertArrayEquals(intArrayOf(payload.size), result.parameters)
        assertArrayEquals(frame(1, 0x101B, 1, parameters(42, 0, payload.size.toLong())), io.written.toByteArray())
    }

    @Test fun transactionIncrementsAndNonOkResponseIsFullyConsumed() {
        val io = FakeIo()
        io.enqueue(response(1, 0x201D), response(2))
        val protocol = session(io)
        assertEquals(0x201D, protocol.exchange(0x1004).code)
        assertFalse(protocol.poisoned)
        assertEquals(0x2001, protocol.exchange(0x1003).code)
        assertArrayEquals(frame(1, 0x1004, 1) + frame(1, 0x1003, 2), io.written.toByteArray())
    }

    @Test fun streamUsesPacketAlignedChunksAndTerminatesExactPacketLengthWithZlp() {
        val payload = ByteArray(32768 - 12) { (it % 251).toByte() }
        val io = FakeIo(packetSize = 512)
        io.enqueue(response(1))
        session(io).exchange(0x100D, outgoing = ByteArrayInputStream(payload), outgoingBytes = payload.size.toLong())
        assertArrayEquals(frame(1, 0x100D, 1) + frame(2, 0x100D, 1, payload), io.written.toByteArray())
        assertEquals(listOf(12, 16384, 16384, 0), io.writeSizes)
    }

    @Test fun nonAlignedStreamEndsWithShortPacketAndSupportsShortWrites() {
        val payload = ByteArray(32769) { it.toByte() }
        val io = FakeIo(writeLimit = 113)
        io.enqueue(response(1))
        session(io).exchange(0x100D, outgoing = ByteArrayInputStream(payload), outgoingBytes = payload.size.toLong())
        assertArrayEquals(frame(1, 0x100D, 1) + frame(2, 0x100D, 1, payload), io.written.toByteArray())
        assertFalse(io.writeSizes.contains(0))
    }

    @Test fun incomingZlpBeforeResponseIsSkippedBoundedly() {
        val io = FakeIo()
        io.enqueue(frame(2, 0x101B, 1, ByteArray(52)), byteArrayOf(), response(1, 0x2001, 52))
        assertEquals(52, session(io).exchange(0x101B).data?.size)
        val stalled = FakeIo().apply { readResult = 0 }
        val protocol = session(stalled)
        fails { protocol.exchange(0x1004) }
        assertTrue(protocol.poisoned)
        assertEquals(5, stalled.reads)
    }

    @Test fun malformedTransactionOpcodeTypeAndLengthPoisonConnection() {
        val bad = listOf(
            response(2),
            frame(2, 0x1005, 1),
            frame(4, 0x4002, 1),
            MtpBulkProtocol.containerHeader(3, 0x2001, 1, 11),
            MtpBulkProtocol.containerHeader(2, 0x1004, 1, 0xFFFF_FFFFL),
            frame(3, 0x2001, 1, byteArrayOf(1)),
            frame(3, 0x1001, 1),
            frame(3, 0x2001, 1, ByteArray(24)),
            response(1) + response(2),
        )
        for (bytes in bad) {
            val io = FakeIo().apply { enqueue(bytes) }
            val protocol = session(io)
            fails { protocol.exchange(0x1004) }
            assertTrue(protocol.poisoned)
            val written = io.written.size()
            fails { protocol.exchange(0x1003) }
            assertEquals(written, io.written.size())
        }
    }

    @Test fun oversizedReadDataRejectedBeforeBodyAllocationOrFurtherReads() {
        val io = FakeIo().apply { enqueue(MtpBulkProtocol.containerHeader(2, 0x101B, 1, 65549)) }
        fails { session(io).exchange(0x101B, maxDataBytes = 65536) }
        assertEquals(1, io.reads)
    }

    @Test fun shortExtraAndOversizedOutgoingSourcesFail() {
        for (declared in listOf(9L, 11L)) {
            val io = FakeIo()
            val protocol = session(io)
            fails("usb_invalid_file") {
                protocol.exchange(0x100D, outgoing = ByteArrayInputStream(ByteArray(10)), outgoingBytes = declared)
            }
            assertTrue(protocol.poisoned)
        }
        val io = FakeIo()
        fails {
            session(io).exchange(0x100D, outgoing = ByteArrayInputStream(byteArrayOf()),
                outgoingBytes = UsbBookSource.MAX_BYTES + 1)
        }
        assertEquals(0, io.written.size())
    }

    @Test fun failedOrZeroUsbWritesAndFailedReadsPoisonTransport() {
        for (result in listOf(-1, 0, 100000)) {
            val io = FakeIo().apply { writeResult = result }
            val protocol = session(io)
            fails { protocol.exchange(0x1004) }
            assertTrue(protocol.poisoned)
        }
        val io = FakeIo().apply { readResult = -1 }
        val protocol = session(io)
        fails { protocol.exchange(0x1004) }
        assertTrue(protocol.poisoned)
    }

    @Test fun cancellationBeforeTransactionAllowsCleanupButDuringWritePoisons() {
        var cancelled = true
        val io = FakeIo().apply { enqueue(response(1)) }
        val protocol = session(io) { cancelled }
        fails("usb_cancelled") { protocol.exchange(0x1004) }
        assertFalse(protocol.poisoned)
        assertEquals(0, io.written.size())
        assertEquals(0x2001, protocol.exchange(0x100B, ignoreCancellation = true).code)
        cancelled = false
        io.afterWrite = { cancelled = true }
        fails("usb_cancelled") { protocol.exchange(0x1004) }
        assertTrue(protocol.poisoned)
    }

    @Test fun transactionHasTotalDeadlineEvenWhileIndividualReadsSucceed() {
        var clock = 0L
        val io = FakeIo(readLimit = 1).apply { enqueue(response(1)) }
        val protocol = MtpBulkProtocol(io, { false }, nowMs = { clock++ }).apply { beginSession() }
        fails { protocol.exchange(0x1004, timeoutMs = 8) }
        assertTrue(protocol.poisoned)
        assertTrue(io.reads < 12)
    }

    @Test fun stringsEncodeUtf16UnitsWithNullTerminatorAndRejectMalformedData() {
        assertArrayEquals(byteArrayOf(0), dataset { string("") })
        assertArrayEquals(byteArrayOf(3, 0x10, 4, 0x11, 4, 0, 0), dataset { string("АБ") })
        val text = "Kindle 📚"
        val encoded = dataset { string(text) }
        assertEquals(text.length + 1, encoded[0].toInt())
        val reader = MtpDatasetReader(encoded)
        assertEquals(text, reader.string()); reader.end()
        for (bytes in listOf(byteArrayOf(2, 65, 0), byteArrayOf(1, 1, 0),
            byteArrayOf(2, 0, 0xD8.toByte(), 0, 0), byteArrayOf(3, 0, 0, 65, 0, 0, 0))) {
            fails { MtpDatasetReader(bytes).string() }
        }
        try { dataset { string("a".repeat(255)) }; fail("Expected long string rejection") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun arraysAndUnsignedValuesAreValidatedBeforeAllocation() {
        fails { MtpDatasetReader(parameters(0xFFFF_FFFFL)).array32(4096) }
        fails { MtpDatasetReader(parameters(3, 1)).array32(4096) }
        fails { MtpDatasetReader(ByteArray(8) { 0xFF.toByte() }).u64() }
        fails { MtpDatasetReader(byteArrayOf(1)).end() }
        assertEquals(0xFFFF_FFFFL, MtpDatasetReader(parameters(0xFFFF_FFFFL)).u32())
    }

    private fun deviceInfo(operations: IntArray = intArrayOf(0x1002, 0x1003, 0x1004, 0x1005,
        0x1007, 0x1008, 0x100B, 0x100C, 0x100D, 0x101B)) = dataset {
        u16(100); u32(6); u16(100); string("microsoft.com: 1.0;"); u16(0)
        u32(operations.size.toLong()); operations.forEach(::u16)
        repeat(4) { u32(0) }
        string("Amazon"); string("Kindle"); string("1.0"); string("not-logged")
    }
    private fun initializedIo() = FakeIo().apply {
        enqueue(response(0), frame(2, 0x1001, 1, deviceInfo()) + response(1))
    }

    @Test fun unsupportedDeviceOrMalformedExistingSessionClosesOwnedTransport() {
        val unsupported = FakeIo().apply {
            enqueue(response(0), frame(2, 0x1001, 1, deviceInfo(intArrayOf(0x1002))) + response(1), response(2))
        }
        fails("usb_unsupported") { UsbBulkMtpPort(unsupported) { false } }
        assertTrue(unsupported.closed)
        val alreadyOpen = FakeIo().apply {
            enqueue(response(0, 0x201E))
        }
        fails { UsbBulkMtpPort(alreadyOpen) { false } }
        assertTrue(alreadyOpen.closed)
        assertEquals(16, alreadyOpen.written.size()) // No commands follow malformed session metadata.
    }

    @Test fun portOpensOwnSessionWritesThenReadsAndDeletesOnlyExplicitObject() {
        val io = initializedIo()
        val port = UsbBulkMtpPort(io) { false }
        io.enqueue(frame(2, 0x1004, 2, parameters(1, 0x10001)) + response(2))
        assertArrayEquals(intArrayOf(0x10001), port.storages())
        val storageInfo = dataset {
            u16(3); u16(2); u16(0); u32(1000000); u32(0); u32(900000); u32(0)
            u32(100); string("Internal storage"); string("")
        }
        io.enqueue(frame(2, 0x1005, 3, storageInfo) + response(3))
        assertEquals(900000L, port.freeBytes(0x10001))
        io.enqueue(frame(2, 0x1007, 4, parameters(1, 17)) + response(4))
        assertArrayEquals(intArrayOf(17), port.handles(0x10001, -1))
        val name = "brizfi-00000000-0000-0000-0000-000000000001.azw3"
        io.enqueue(response(5, 0x2001, 0x10001, 17, 42))
        val created = port.create(0x10001, 17, name, 100)
        assertEquals(42, created.handle)
        assertEquals(name, created.name)
        val file = Files.createTempFile("brizfi-usb-bulk", ".azw3").toFile()
        val bytes = ByteArray(100) { it.toByte() }
        try {
            file.writeBytes(bytes)
            io.enqueue(response(6))
            assertTrue(port.send(42, UsbBookSource.Source(file, 100, MessageDigest.getInstance("SHA-256").digest(bytes))))
            val objectInfo = dataset {
                u32(0x10001); u16(0x3000); u16(0); u32(100); u16(0)
                repeat(6) { u32(0) }
                u32(17); u16(0); u32(0); u32(0); string(name); repeat(3) { string("") }
            }
            io.enqueue(frame(2, 0x1008, 7, objectInfo) + response(7))
            assertEquals(created, port.info(42))
            io.enqueue(frame(2, 0x101B, 8, bytes) + response(8, 0x2001, 100))
            val readback = ByteArray(100)
            assertEquals(100L, port.read(42, 0, 100, readback))
            assertArrayEquals(bytes, readback)
            io.enqueue(response(9))
            assertTrue(port.delete(42))
            io.enqueue(response(10))
            port.close(); port.close()
            assertTrue(io.closed)
            val wire = io.written.toByteArray()
            // OpenSession uses transaction zero; GetDeviceInfo starts the session transactions.
            assertEquals(0L, MtpDatasetReader(wire.copyOfRange(8, 12)).u32())
            assertTrue(wire.size < 4096)
        } finally { file.delete() }
    }

    @Test fun partialObjectResponseCountMustMatchDataAndCannotExceedRequest() {
        val io = initializedIo()
        val port = UsbBulkMtpPort(io) { false }
        io.enqueue(frame(2, 0x101B, 2, ByteArray(10)) + response(2, 0x2001, 11))
        fails("usb_verification_failed") { port.read(42, 0, 10, ByteArray(10)) }
        io.enqueue(response(3))
        port.close()
        assertTrue(io.closed)
    }

    @Test fun wildcardDeletionAndInvalidReadBoundsCannotReachUsb() {
        val io = initializedIo()
        val port = UsbBulkMtpPort(io) { false }
        val before = io.written.size()
        fails { port.delete(-1) }; fails { port.delete(0) }
        fails { port.read(42, -1, 1, ByteArray(1)) }
        fails { port.read(42, 0, 65537, ByteArray(65537)) }
        fails { port.read(42, UsbBookSource.MAX_BYTES, 1, ByteArray(1)) }
        assertEquals(before, io.written.size())
        io.enqueue(response(2)); port.close()
    }

    @Test fun synchronizedCancellationAllowsIdentityReadDeleteAndCloseForCoreCleanup() {
        var cancelled = false
        val io = initializedIo()
        val port = UsbBulkMtpPort(io) { cancelled }
        cancelled = true
        io.enqueue(response(2, 0x2009))
        assertNull(port.info(42))
        io.enqueue(frame(2, 0x1007, 3, parameters(0)) + response(3))
        assertArrayEquals(intArrayOf(), port.handles(0x10001, 17))
        io.enqueue(response(4))
        assertTrue(port.delete(42))
        val before = io.written.size()
        fails("usb_cancelled") { port.read(42, 0, 1, ByteArray(1)) }
        assertEquals(before, io.written.size())
        io.enqueue(response(5)); port.close()
        assertTrue(io.closed)
    }

    @Test fun initialCommandsOpenSessionThenGetDeviceInfoWithAospTransactionIds() {
        val io = initializedIo()
        val port = UsbBulkMtpPort(io) { false }
        val commands = MtpDatasetReader(io.written.toByteArray())
        assertEquals(16L, commands.u32()); assertEquals(1, commands.u16())
        assertEquals(0x1002, commands.u16()); assertEquals(0L, commands.u32())
        assertTrue(commands.u32() > 0)
        assertEquals(12L, commands.u32()); assertEquals(1, commands.u16())
        assertEquals(0x1001, commands.u16()); assertEquals(1L, commands.u32())
        commands.end()
        io.enqueue(response(2)); port.close()
        assertTrue(io.closed)
    }

    @Test fun malformedInitialMetadataClosesOwnedSessionAndPreservesPrimaryFailure() {
        for (closeCode in listOf(0x2001, 0x201D)) {
            val io = FakeIo().apply {
                enqueue(response(0), frame(2, 0x1001, 1, byteArrayOf(1)) + response(1), response(2, closeCode))
            }
            fails("usb_unsupported") { UsbBulkMtpPort(io) { false } }
            assertTrue(io.closed)
            val written = io.written.toByteArray()
            assertArrayEquals(frame(1, 0x1003, 2), written.copyOfRange(written.size - 12, written.size))
        }
    }

    @Test fun existingSessionRequiresExactlyOneNonzeroUnsignedId() {
        for (ids in listOf(longArrayOf(), longArrayOf(0), longArrayOf(1, 2))) {
            val io = FakeIo().apply { enqueue(response(0, 0x201E, *ids)) }
            fails("usb_transfer_failed") { UsbBulkMtpPort(io) { false } }
            assertTrue(io.closed)
            assertEquals(16, io.written.size())
        }
        val withData = FakeIo().apply {
            enqueue(frame(2, 0x1002, 0, byteArrayOf(1)) + response(0, 0x201E, 1))
        }
        fails("usb_transfer_failed") { UsbBulkMtpPort(withData) { false } }
        assertTrue(withData.closed)
        assertEquals(16, withData.written.size())
    }

    @Test fun existingSessionUsesTransactionOneAndClosesOnlyItsOwnUsbConnection() {
        // The protocol SessionID is unsigned; high-bit values must not be rejected as negative Ints.
        for (id in listOf(1L, 0x8000_0000L, 0xFFFF_FFFFL)) {
            val io = FakeIo().apply {
                enqueue(response(0, 0x201E, id), frame(2, 0x1001, 1, deviceInfo()) + response(1))
            }
            val port = UsbBulkMtpPort(io) { false }
            io.enqueue(frame(2, 0x1004, 2, parameters(1, 0x10001)) + response(2))
            assertArrayEquals(intArrayOf(0x10001), port.storages())
            val before = io.written.toByteArray()
            port.close(); port.close()
            assertTrue(io.closed)
            assertArrayEquals(before, io.written.toByteArray()) // No CloseSession or reset.
            assertArrayEquals(frame(1, 0x1001, 1), before.copyOfRange(16, 28))
        }
    }

    @Test fun existingSessionMetadataFailureNeverClosesBorrowedSession() {
        for (metadata in listOf(byteArrayOf(1), deviceInfo(intArrayOf(0x1002)))) {
            val io = FakeIo().apply {
                enqueue(response(0, 0x201E, 1), frame(2, 0x1001, 1, metadata) + response(1))
            }
            fails("usb_unsupported") { UsbBulkMtpPort(io) { false } }
            assertTrue(io.closed)
            assertEquals(28, io.written.size())
            assertArrayEquals(frame(1, 0x1001, 1), io.written.toByteArray().copyOfRange(16, 28))
        }
    }

    @Test fun cancellationAfterBorrowingSessionClosesOnlyUsbConnection() {
        var cancelled = false
        val io = FakeIo().apply {
            enqueue(response(0, 0x201E, 1), frame(2, 0x1001, 1, deviceInfo()) + response(1))
        }
        val port = UsbBulkMtpPort(io) { cancelled }
        val before = io.written.toByteArray()
        cancelled = true
        fails("usb_cancelled") { port.storages() }
        port.close()
        assertTrue(io.closed)
        assertArrayEquals(before, io.written.toByteArray())
    }

    @Test fun diagnosticCallbackCannotAlterFailureOrExposeDataset() {
        val io = FakeIo().apply { readResult = -1 }
        val events = mutableListOf<Pair<Int, String>>()
        val protocol = MtpBulkProtocol(io, { false }, onFailure = { op, phase ->
            events.add(op to phase)
            throw IllegalStateException("diagnostic unavailable")
        }).apply { beginSession() }
        fails("usb_transfer_failed") { protocol.exchange(0x1004) }
        assertEquals(listOf(0x1004 to "read-header"), events)
        assertTrue(protocol.poisoned)
    }
}
