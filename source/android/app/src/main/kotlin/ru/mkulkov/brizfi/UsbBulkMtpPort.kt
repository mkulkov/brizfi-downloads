package ru.mkulkov.brizfi

import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbRequest
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.SecureRandom
import java.util.concurrent.TimeoutException

/**
 * Bounded MTP initiator for the verified Kindle vendor interface. Runs only on the USB worker.
 * Uses public USB bulk APIs, avoiding Android MtpDevice's vendor interface STRING probe.
 * Dataset layout follows AOSP android-14.0.0_r1 media/mtp (MtpDevice/ObjectInfo/DataPacket).
 */
internal class UsbBulkMtpPort internal constructor(
    private val io: MtpBulkIo,
    onFailure: (Int, String) -> Unit = { _, _ -> },
    cancelled: () -> Boolean,
) : UsbMtpPort, AutoCloseable {
    private val protocol = MtpBulkProtocol(io, cancelled, onFailure = onFailure)
    private var supported = intArrayOf()
    private var session = false
    private var ownsSession = false
    private var closed = false
    private var pending: UsbMtpPort.ObjectInfo? = null
    private var pendingTransaction = 0

    init {
        try {
            val sessionId = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
            val response = protocol.exchange(OPEN_SESSION, intArrayOf(sessionId), sessionless = true)
            if (response.data != null) fail("usb_transfer_failed")
            if (response.code == SESSION_ALREADY_OPEN) {
                // A non-forced USB claim provides exclusive access, but does not confer ownership
                // of a session left open by another client. Accept any nonzero unsigned SessionID.
                if (response.parameters.size != 1 || response.parameters[0] == 0) fail("usb_transfer_failed")
            } else {
                requireOk(response, 0)
                ownsSession = true
            }
            session = true
            protocol.beginSession()
            // Match AOSP initialization: OpenSession TID 0, then GetDeviceInfo TID 1.
            val device = MtpDatasetReader(data(protocol.exchange(GET_DEVICE_INFO)))
            device.u16(); device.u32(); device.u16(); device.string(); device.u16()
            supported = device.array16(1024)
            repeat(4) { device.array16(1024) }
            repeat(4) { device.string() }
            device.end()
            if (!supported.toSet().containsAll(REQUIRED)) fail("usb_unsupported")
        } catch (error: Exception) {
            // Retire only our opened session if synchronized, preserving the primary error.
            runCatching { close() }
            throw error
        }
    }

    override fun operations(): IntArray = supported.copyOf()

    override fun storages(): IntArray {
        val reader = MtpDatasetReader(data(protocol.exchange(GET_STORAGE_IDS)))
        return reader.array32(32).also { reader.end() }
    }

    override fun freeBytes(storage: Int): Long {
        val reader = MtpDatasetReader(data(protocol.exchange(GET_STORAGE_INFO, intArrayOf(storage))))
        reader.u16(); reader.u16()
        val access = reader.u16()
        reader.u64()
        val free = reader.u64()
        reader.u32(); reader.string(); reader.string(); reader.end()
        // AccessCapability 0 is read/write. Read-only media must never enter the write path.
        if (access != 0) fail("usb_unsupported")
        return free
    }

    override fun handles(storage: Int, parent: Int): IntArray {
        val reader = MtpDatasetReader(data(protocol.exchange(GET_OBJECT_HANDLES,
            intArrayOf(storage, 0, parent), ignoreCancellation = true)))
        return reader.array32(4096).also { reader.end() }
    }

    override fun info(handle: Int): UsbMtpPort.ObjectInfo? {
        val response = protocol.exchange(GET_OBJECT_INFO, intArrayOf(handle), ignoreCancellation = true)
        if (response.code == INVALID_OBJECT_HANDLE && response.data == null) return null
        val reader = MtpDatasetReader(data(response))
        val storage = reader.u32().toInt()
        val format = reader.u16()
        val protection = reader.u16()
        val bytes = reader.u32()
        reader.u16()
        repeat(6) { reader.u32() }
        val parent = reader.u32().toInt()
        reader.u16(); reader.u32(); reader.u32()
        val name = reader.string()
        repeat(3) { reader.string() }
        reader.end()
        return UsbMtpPort.ObjectInfo(handle, storage, parent, format, protection, name, bytes)
    }

    override fun create(storage: Int, parent: Int, name: String, bytes: Long): UsbMtpPort.ObjectInfo {
        if (pending != null || bytes !in 86..UsbBookSource.MAX_BYTES ||
            !Regex("brizfi-[0-9a-f-]{36}\\.azw3").matches(name) || parent == 0 || parent == -1
        ) fail("usb_invalid_file")
        val writer = MtpDatasetWriter()
        writer.u32(storage.toLong() and UINT_MAX); writer.u16(0x3000); writer.u16(0)
        writer.u32(bytes); writer.u16(0)
        repeat(6) { writer.u32(0) }
        writer.u32(parent.toLong() and UINT_MAX); writer.u16(0); writer.u32(0); writer.u32(0)
        writer.string(name); repeat(3) { writer.string("") }
        val payload = writer.bytes()
        val response = protocol.exchange(SEND_OBJECT_INFO, intArrayOf(storage, parent),
            outgoing = ByteArrayInputStream(payload), outgoingBytes = payload.size.toLong())
        requireOk(response, 3)
        val values = response.parameters
        if (values[0] != storage || values[1] != parent || values[2] == 0 || values[2] == -1) {
            fail("usb_uncertain")
        }
        return UsbMtpPort.ObjectInfo(values[2], storage, parent, 0x3000, 0, name, bytes).also {
            pending = it
            pendingTransaction = protocol.nextTransaction
        }
    }

    override fun send(handle: Int, source: UsbBookSource.Source): Boolean {
        val created = pending ?: fail("usb_transfer_failed")
        if (created.handle != handle || source.bytes != created.bytes ||
            protocol.nextTransaction != pendingTransaction || source.bytes !in 86..UsbBookSource.MAX_BYTES ||
            source.file.length() != source.bytes
        ) fail("usb_invalid_file")
        pending = null
        source.file.inputStream().use { input ->
            val response = protocol.exchange(SEND_OBJECT, outgoing = input,
                outgoingBytes = source.bytes, timeoutMs = 120_000)
            requireOk(response, 0)
        }
        return true
    }

    override fun read(handle: Int, offset: Long, length: Int, buffer: ByteArray): Long {
        if (offset < 0 || length !in 1..65536 || length > buffer.size ||
            offset + length > UsbBookSource.MAX_BYTES
        ) fail("usb_verification_failed")
        val response = protocol.exchange(GET_PARTIAL_OBJECT, intArrayOf(handle, offset.toInt(), length),
            maxDataBytes = length)
        requireOk(response, 1)
        val payload = response.data ?: fail("usb_verification_failed")
        val count = response.parameters[0].toLong() and UINT_MAX
        if (count != payload.size.toLong() || count > length) fail("usb_verification_failed")
        payload.copyInto(buffer)
        return count
    }

    override fun delete(handle: Int): Boolean {
        // Authorization of object identity belongs to UsbTransferCore. Never accept wildcard handles.
        if (handle == 0 || handle == -1) fail("usb_uncertain")
        val response = protocol.exchange(DELETE_OBJECT, intArrayOf(handle, 0), ignoreCancellation = true)
        requireOk(response, 0)
        return true
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            if (session && ownsSession && !protocol.poisoned) {
                requireOk(protocol.exchange(CLOSE_SESSION, timeoutMs = 2000, ignoreCancellation = true), 0)
            }
        } finally {
            session = false
            ownsSession = false
            io.close()
        }
    }

    private fun data(response: MtpBulkProtocol.Response): ByteArray {
        requireOk(response, 0)
        return response.data ?: fail("usb_unsupported")
    }

    private fun requireOk(response: MtpBulkProtocol.Response, parameters: Int) {
        if (response.code != OK || response.parameters.size != parameters) fail("usb_transfer_failed")
    }

    companion object {
        private const val GET_DEVICE_INFO = 0x1001
        private const val OPEN_SESSION = 0x1002
        private const val CLOSE_SESSION = 0x1003
        private const val GET_STORAGE_IDS = 0x1004
        private const val GET_STORAGE_INFO = 0x1005
        private const val GET_OBJECT_HANDLES = 0x1007
        private const val GET_OBJECT_INFO = 0x1008
        private const val DELETE_OBJECT = 0x100B
        private const val SEND_OBJECT_INFO = 0x100C
        private const val SEND_OBJECT = 0x100D
        private const val GET_PARTIAL_OBJECT = 0x101B
        private const val OK = 0x2001
        private const val INVALID_OBJECT_HANDLE = 0x2009
        private const val SESSION_ALREADY_OPEN = 0x201E
        private const val UINT_MAX = 0xFFFF_FFFFL
        private val REQUIRED = setOf(OPEN_SESSION, CLOSE_SESSION, GET_STORAGE_IDS, GET_STORAGE_INFO,
            GET_OBJECT_HANDLES, GET_OBJECT_INFO, DELETE_OBJECT, SEND_OBJECT_INFO, SEND_OBJECT, GET_PARTIAL_OBJECT)

        /** Owns and closes [connection], including every failure during interface/session opening. */
        fun open(device: UsbDevice, connection: UsbDeviceConnection, cancelled: () -> Boolean): UsbBulkMtpPort =
            open(device, connection, { _, _ -> }, cancelled)

        /** Optional failure diagnostics contain only the operation code and a fixed protocol phase. */
        fun open(device: UsbDevice, connection: UsbDeviceConnection,
            onFailure: (Int, String) -> Unit,
            cancelled: () -> Boolean,
        ): UsbBulkMtpPort {
            var transport: AndroidMtpBulkIo? = null
            try {
                if (device.vendorId != 0x1949 || device.productId != 0x9981) fail("usb_unsupported")
                val matches = (0 until device.interfaceCount).map { device.getInterface(it) }.filter {
                    it.interfaceClass == 255 && it.interfaceSubclass == 255 && it.interfaceProtocol == 0
                }
                if (matches.size != 1) fail("usb_unsupported")
                val iface = matches.single()
                val endpoints = (0 until iface.endpointCount).map { iface.getEndpoint(it) }
                val input = endpoints.filter { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    it.direction == UsbConstants.USB_DIR_IN }.singleOrNull() ?: fail("usb_unsupported")
                val output = endpoints.filter { it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    it.direction == UsbConstants.USB_DIR_OUT }.singleOrNull() ?: fail("usb_unsupported")
                if (input.maxPacketSize !in setOf(64, 512, 1024) ||
                    output.maxPacketSize !in setOf(64, 512, 1024)
                ) fail("usb_unsupported")
                // Never disconnect an interface held by another Android USB client.
                if (!connection.claimInterface(iface, false)) fail("usb_busy")
                transport = AndroidMtpBulkIo(connection, iface, input, output, onFailure)
                return UsbBulkMtpPort(transport, onFailure, cancelled)
            } catch (error: Exception) {
                if (transport != null) transport.close() else connection.close()
                throw error
            }
        }

        private fun fail(code: String): Nothing = throw UsbTransferFailure(code)
    }
}

/** Exact-length requests are buffered above this layer: USB packets may combine whole containers. */
internal interface MtpBulkIo : AutoCloseable {
    val packetSize: Int
    fun read(buffer: ByteArray, timeoutMs: Int): Int
    fun write(buffer: ByteArray, offset: Int, length: Int, timeoutMs: Int): Int
}

private class AndroidMtpBulkIo(
    private val connection: UsbDeviceConnection,
    private val iface: UsbInterface,
    private val input: UsbEndpoint,
    private val output: UsbEndpoint,
    private val onFailure: (Int, String) -> Unit,
) : MtpBulkIo {
    private var closed = false
    private val readRequest = UsbRequest()
    private val writeRequest = UsbRequest()
    private val readBuffer = ByteBuffer.allocateDirect(16 * 1024)
    private val writeBuffer = ByteBuffer.allocateDirect(16 * 1024)
    // Both direct buffers remain strongly owned until completion or connection.close() returns.
    private var pending: UsbRequest? = null
    private var inputDiagnosed = false
    private var outputDiagnosed = false
    override val packetSize = output.maxPacketSize

    init {
        try {
            if (!readRequest.initialize(connection, input) || !writeRequest.initialize(connection, output)) {
                runCatching { onFailure(0, "async-request-initialize") }
                throw UsbTransferFailure("usb_open_failed")
            }
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    override fun read(buffer: ByteArray, timeoutMs: Int): Int {
        if (closed) return -1
        if (buffer.isEmpty() || buffer.size > readBuffer.capacity()) return failed(input, "bounds")
        readBuffer.clear()
        readBuffer.limit(buffer.size)
        val count = exchange(readRequest, input, readBuffer, buffer.size, timeoutMs)
        if (count >= 0) {
            readBuffer.flip()
            readBuffer.get(buffer, 0, count)
        }
        return count
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int, timeoutMs: Int): Int {
        if (closed) return -1
        if (offset < 0 || length < 0 || offset > buffer.size || length > buffer.size - offset ||
            length > writeBuffer.capacity()
        ) return failed(output, "bounds")
        writeBuffer.clear()
        writeBuffer.put(buffer, offset, length)
        writeBuffer.flip() // Includes a zero remaining-byte buffer for an explicit data-phase ZLP.
        val count = exchange(writeRequest, output, writeBuffer, length, timeoutMs)
        if (count == 0 && length > 0) return failed(output, "zero-completion")
        return count
    }

    private fun exchange(request: UsbRequest, endpoint: UsbEndpoint, buffer: ByteBuffer,
        length: Int, timeoutMs: Int,
    ): Int {
        if (closed) return -1
        if (pending != null || timeoutMs <= 0) return failed(endpoint, "state")
        var phase = "queue"
        val started = System.nanoTime()
        try {
            // Keep the request/buffer alive even if queue() throws after native submission.
            pending = request
            if (!request.queue(buffer)) return failed(endpoint, "queue-rejected")
            phase = "wait"
            val completed = connection.requestWait(timeoutMs.toLong())
            if (completed !== request) return failed(endpoint, if (completed == null) "wait-null" else "wait-other-request")
            pending = null
            // queue(ByteBuffer) advances position by actual bytes only after requestWait completes.
            val count = buffer.position()
            if (count !in 0..length) return failed(endpoint, "invalid-count")
            val isInput = endpoint.direction == UsbConstants.USB_DIR_IN
            if (if (isInput) !inputDiagnosed else !outputDiagnosed) {
                if (isInput) inputDiagnosed = true else outputDiagnosed = true
                runCatching { onFailure(0, "async-${if (isInput) "in" else "out"}-count=$count " +
                    "elapsed-ms=${(System.nanoTime() - started) / 1_000_000}") }
            }
            return count
        } catch (_: TimeoutException) {
            return failed(endpoint, "timeout")
        } catch (_: Exception) {
            return failed(endpoint, "$phase-exception")
        }
    }

    private fun failed(endpoint: UsbEndpoint, phase: String): Int {
        runCatching {
            onFailure(0, "async-${if (endpoint.direction == UsbConstants.USB_DIR_IN) "in" else "out"}-$phase " +
                "endpoint=${endpoint.address} fd-open=${connection.fileDescriptor >= 0}")
        }
        close()
        return -1
    }

    override fun close() {
        if (closed) return
        closed = true
        val unfinished = pending
        if (unfinished != null) {
            runCatching { unfinished.cancel() }
            // cancel() is not proof of completion. Closing the USB fd retires pending native URBs
            // before requests are freed; no pending buffer is cleared, inspected, or reused.
            try { connection.close() } finally {
                pending = null
                runCatching { readRequest.close() }
                runCatching { writeRequest.close() }
            }
        } else {
            try {
                runCatching { readRequest.close() }
                runCatching { writeRequest.close() }
                connection.releaseInterface(iface)
            } finally { connection.close() }
        }
    }
}

/** Pure bounded USB container/stream codec; no Android framework calls in JVM tests. */
internal class MtpBulkProtocol(
    private val io: MtpBulkIo,
    private val cancelled: () -> Boolean,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
    private val onFailure: (Int, String) -> Unit = { _, _ -> },
) {
    data class Response(val code: Int, val parameters: IntArray, val data: ByteArray?)
    var nextTransaction = 0
        private set
    var poisoned = false
        private set
    private val incoming = ByteArray(CHUNK)
    private var incomingOffset = 0
    private var incomingCount = 0
    private var deadline = 0L
    private var ignoreCancellation = false

    fun beginSession() { nextTransaction = 1 }

    fun exchange(
        operation: Int,
        parameters: IntArray = intArrayOf(),
        sessionless: Boolean = false,
        outgoing: InputStream? = null,
        outgoingBytes: Long = 0,
        maxDataBytes: Int = 1024 * 1024,
        timeoutMs: Int = 15_000,
        ignoreCancellation: Boolean = false,
    ): Response {
        if (poisoned) fail()
        if (parameters.size > 5 || operation !in 0x1000..0x1FFF || maxDataBytes !in 0..1024 * 1024 ||
            outgoingBytes !in 0..UsbBookSource.MAX_BYTES || (outgoing == null && outgoingBytes != 0L) ||
            timeoutMs !in 1..120_000 || (!sessionless && nextTransaction == 0)
        ) fail()
        this.ignoreCancellation = ignoreCancellation
        deadline = nowMs() + timeoutMs
        checkReady() // Cancellation before a transaction preserves the synchronized connection for cleanup.
        val transaction = if (sessionless) 0 else nextTransaction++
        if (nextTransaction < 0) fail()
        var started = false
        var phase = "command"
        try {
            val command = MtpDatasetWriter().apply { parameters.forEach { u32(it.toLong() and UINT_MAX) } }.bytes()
            started = true
            writeAll(container(1, operation, transaction, command), command.size + HEADER)
            if (outgoing != null) {
                phase = "write-data"
                writeStream(operation, transaction, outgoing, outgoingBytes)
            }
            var payload: ByteArray? = null
            phase = "read-header"
            var header = readHeader(transaction)
            if (header.type == 2) {
                if (outgoing != null || header.code != operation || header.length - HEADER > maxDataBytes) fail()
                phase = "read-data"
                payload = readExact(header.length - HEADER)
                phase = "read-response"
                header = readHeader(transaction)
            }
            if (header.type != 3 || header.code !in 0x2000..0x2FFF ||
                header.length !in HEADER..(HEADER + 20) || (header.length - HEADER) % 4 != 0
            ) fail()
            val reader = MtpDatasetReader(readExact(header.length - HEADER))
            val values = IntArray((header.length - HEADER) / 4) { reader.u32().toInt() }
            reader.end()
            // Never carry unsolicited bytes into another request (events use the interrupt endpoint).
            if (incomingCount != incomingOffset) fail()
            if (header.code != 0x2001) runCatching { onFailure(operation, "response-${header.code.toString(16)}") }
            return Response(header.code, values, payload)
        } catch (error: Exception) {
            if (started) poisoned = true
            runCatching { onFailure(operation, phase) } // Diagnostics can never alter protocol handling.
            throw error
        }
    }

    private data class Header(val length: Int, val type: Int, val code: Int)
    private fun readHeader(transaction: Int): Header {
        val reader = MtpDatasetReader(readExact(HEADER))
        val length = reader.u32()
        val type = reader.u16()
        val code = reader.u16()
        val receivedTransaction = reader.u32().toInt()
        if (receivedTransaction != transaction || length < HEADER || length > 1024 * 1024 + HEADER) {
            runCatching { onFailure(code, "header-length=$length type=$type transaction-match=${receivedTransaction == transaction}") }
            fail()
        }
        return Header(length.toInt(), type, code)
    }

    private fun readExact(length: Int): ByteArray {
        val result = ByteArray(length)
        var position = 0
        var emptyPackets = 0
        while (position < length) {
            checkReady()
            if (incomingOffset == incomingCount) {
                incomingOffset = 0
                incomingCount = io.read(incoming, callTimeout())
                if (incomingCount < 0 || incomingCount > incoming.size) fail()
                if (incomingCount == 0) {
                    if (++emptyPackets > 4) {
                        runCatching { onFailure(0, "too-many-empty-input-packets") }
                        fail()
                    }
                    continue // A terminating USB zero-length packet may precede the response.
                }
            }
            val count = minOf(length - position, incomingCount - incomingOffset)
            incoming.copyInto(result, position, incomingOffset, incomingOffset + count)
            incomingOffset += count
            position += count
        }
        return result
    }

    private fun writeStream(operation: Int, transaction: Int, input: InputStream, bytes: Long) {
        val block = ByteArray(CHUNK - CHUNK % io.packetSize)
        val header = containerHeader(2, operation, transaction, bytes + HEADER)
        header.copyInto(block)
        var remaining = bytes
        var prefix = HEADER
        while (remaining > 0 || prefix > 0) {
            checkReady()
            val count = minOf((block.size - prefix).toLong(), remaining).toInt()
            var position = prefix
            while (position < prefix + count) {
                val read = input.read(block, position, prefix + count - position)
                if (read <= 0) throw UsbTransferFailure("usb_invalid_file")
                position += read
            }
            writeAll(block, prefix + count)
            remaining -= count
            prefix = 0
        }
        if (input.read() != -1) throw UsbTransferFailure("usb_invalid_file")
        // A short packet (including a ZLP) terminates a USB data phase of exact packet-size length.
        if ((bytes + HEADER) % io.packetSize == 0L) {
            checkReady()
            if (io.write(ByteArray(0), 0, 0, callTimeout()) != 0) fail()
        }
    }

    private fun writeAll(bytes: ByteArray, length: Int) {
        var offset = 0
        while (offset < length) {
            checkReady()
            val count = io.write(bytes, offset, length - offset, callTimeout())
            if (count <= 0 || count > length - offset) fail()
            offset += count
        }
    }

    private fun checkReady() {
        if (!ignoreCancellation && cancelled()) throw UsbTransferFailure("usb_cancelled")
        if (nowMs() >= deadline) fail()
    }
    private fun callTimeout(): Int = (deadline - nowMs()).coerceIn(1, 1000).toInt()
    private fun fail(): Nothing = throw UsbTransferFailure("usb_transfer_failed")

    companion object {
        private const val CHUNK = 16 * 1024
        private const val HEADER = 12
        private const val UINT_MAX = 0xFFFF_FFFFL
        internal fun containerHeader(type: Int, code: Int, transaction: Int, length: Long): ByteArray =
            MtpDatasetWriter().apply {
                u32(length); u16(type); u16(code); u32(transaction.toLong() and UINT_MAX)
            }.bytes()
        internal fun container(type: Int, code: Int, transaction: Int, payload: ByteArray) =
            containerHeader(type, code, transaction, payload.size.toLong() + HEADER) + payload
    }
}

internal class MtpDatasetReader(private val bytes: ByteArray) {
    private var position = 0
    fun u8(): Int { need(1); return bytes[position++].toInt() and 255 }
    fun u16(): Int = u8() or (u8() shl 8)
    fun u32(): Long = u16().toLong() or (u16().toLong() shl 16)
    fun u64(): Long {
        val low = u32()
        val high = u32()
        if (high > Int.MAX_VALUE) fail()
        return low or (high shl 32)
    }
    fun string(): String {
        val count = u8()
        if (count == 0) return ""
        need(count * 2)
        val start = position
        position += count * 2
        if (bytes[position - 1] != 0.toByte() || bytes[position - 2] != 0.toByte()) fail()
        val text = try {
            Charsets.UTF_16LE.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes, start, count * 2 - 2)).toString()
        } catch (_: Exception) { fail() }
        if ('\u0000' in text) fail()
        return text
    }
    fun array16(max: Int): IntArray {
        val count = u32()
        if (count > max || count > (bytes.size - position) / 2) fail()
        return IntArray(count.toInt()) { u16() }
    }
    fun array32(max: Int): IntArray {
        val count = u32()
        if (count > max || count > (bytes.size - position) / 4) fail()
        return IntArray(count.toInt()) { u32().toInt() }
    }
    fun end() { if (position != bytes.size) fail() }
    private fun need(count: Int) { if (count > bytes.size - position) fail() }
    private fun fail(): Nothing = throw UsbTransferFailure("usb_unsupported")
}

internal class MtpDatasetWriter {
    private val output = ByteArrayOutputStream()
    fun u8(value: Int) { require(value in 0..255); output.write(value) }
    fun u16(value: Int) { require(value in 0..65535); u8(value and 255); u8(value ushr 8) }
    fun u32(value: Long) { require(value in 0..0xFFFF_FFFFL); u16((value and 65535).toInt()); u16((value ushr 16).toInt()) }
    fun string(value: String) {
        require(value.length <= 254 && '\u0000' !in value)
        val encoded = Charsets.UTF_16LE.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(value))
        if (value.isEmpty()) u8(0)
        else {
            u8(value.length + 1)
            while (encoded.hasRemaining()) output.write(encoded.get().toInt() and 255)
            u16(0)
        }
    }
    fun bytes(): ByteArray = output.toByteArray()
}
