package ru.mkulkov.brizfi

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.Locale
import java.util.concurrent.atomic.AtomicReference

internal class UsbTransferFailure(val code: String) : Exception()

/** Only direct, marked app-owned supported book copies may enter the USB transport. */
internal object UsbBookSource {
    const val MAX_BYTES = 32L * 1024 * 1024
    data class Source(val file: File, val bytes: Long, val digest: ByteArray) {
        val extension: String get() = file.extension.lowercase(Locale.ROOT)
    }

    fun inspect(root: File, path: String, profile: UsbReaderProfile = UsbReaderProfile.KINDLE,
                cancelled: () -> Boolean): Source {
        try {
            val file = File(path)
            val directory = file.parentFile ?: throw UsbTransferFailure("usb_invalid_file")
            val marker = File(directory, ".brizfi_owned")
            if (!file.isAbsolute || root.canonicalFile != root.absoluteFile ||
                file.canonicalFile != file.absoluteFile || directory.parentFile != root ||
                Files.isSymbolicLink(root.toPath()) || Files.isSymbolicLink(directory.toPath()) ||
                Files.isSymbolicLink(file.toPath()) || Files.isSymbolicLink(marker.toPath()) ||
                runCatching { UUID.fromString(directory.name).toString() }.getOrNull() != directory.name ||
                !marker.isFile || marker.length() > 128 ||
                marker.readText() != "brizfi-import-v1\n${directory.name}\n" ||
                !file.isFile || file.extension.lowercase(Locale.ROOT) !in profile.formats
            ) throw UsbTransferFailure("usb_invalid_file")
            val size = file.length()
            if (size < 1 || size > MAX_BYTES) throw UsbTransferFailure("usb_invalid_file")
            val digest = MessageDigest.getInstance("SHA-256")
            RandomAccessFile(file, "r").use { input ->
                val content = ByteArray(size.toInt())
                val buffer = ByteArray(64 * 1024)
                var read = 0L
                while (true) {
                    if (cancelled()) throw UsbTransferFailure("usb_cancelled")
                    val count = input.read(buffer)
                    if (count < 0) break
                    read += count
                    if (read > MAX_BYTES || read > size) throw UsbTransferFailure("usb_invalid_file")
                    buffer.copyInto(content, (read - count).toInt(), 0, count)
                    digest.update(buffer, 0, count)
                }
                if (read != size) throw UsbTransferFailure("usb_invalid_file")
                UsbBookFormat.validate(content, file.extension.lowercase(Locale.ROOT), cancelled)
            }
            return Source(file, size, digest.digest())
        } catch (error: UsbTransferFailure) {
            throw error
        } catch (_: Exception) {
            throw UsbTransferFailure("usb_invalid_file")
        }
    }
}

/** Shared across Activity instances until the old native worker has stopped reading. */
internal class UsbTransferLease {
    private sealed class State {
        data object Idle : State()
        data object Collecting : State()
        data class Reading(val path: String) : State()
    }
    private val source = AtomicReference<State>(State.Idle)
    fun claim(path: String): Boolean = source.compareAndSet(State.Idle, State.Reading(path))
    fun release(path: String) {
        val held = source.get()
        if (held is State.Reading && held.path == path) source.compareAndSet(held, State.Idle)
    }
    fun usesImport(path: String): Boolean {
        val held = source.get() as? State.Reading ?: return false
        return runCatching {
            val directory = File(held.path).canonicalFile.parentFile
            val target = File(path).canonicalFile
            target == directory || target.parentFile == directory
        }.getOrDefault(true)
    }
    fun collectIfIdle(operation: () -> Unit): Boolean {
        if (!source.compareAndSet(State.Idle, State.Collecting)) return false
        try { operation() } finally { source.compareAndSet(State.Collecting, State.Idle) }
        return true
    }
}

/** Small synchronous port: all calls run on the USB worker, never the Flutter UI thread. */
internal interface UsbMtpPort {
    data class ObjectInfo(
        val handle: Int, val storage: Int, val parent: Int, val format: Int,
        val protection: Int, val name: String, val bytes: Long,
    )
    fun operations(): IntArray?
    fun storages(): IntArray?
    fun freeBytes(storage: Int): Long?
    fun handles(storage: Int, parent: Int): IntArray?
    fun info(handle: Int): ObjectInfo?
    fun create(storage: Int, parent: Int, name: String, bytes: Long): ObjectInfo?
    fun send(handle: Int, source: UsbBookSource.Source): Boolean
    fun read(handle: Int, offset: Long, length: Int, buffer: ByteArray): Long
    fun delete(handle: Int): Boolean
}

/** Creates one new object; success requires matching metadata and bounded SHA-256 readback. */
internal class UsbTransferCore(
    private val port: UsbMtpPort,
    private val cancelled: () -> Boolean,
    private val phase: (String) -> Unit,
    private val newId: () -> UUID = UUID::randomUUID,
) {
    data class Receipt(val bytes: Long, val name: String)
    private data class Destination(val storage: Int, val folder: Int, val children: List<UsbMtpPort.ObjectInfo>)
    private var visits = 0
    private val existingHandles = mutableSetOf<Int>()

    fun transfer(source: UsbBookSource.Source): Receipt {
        var creationStarted = false
        var own: UsbMtpPort.ObjectInfo? = null
        try {
            checkCancelled()
            if (source.extension !in UsbReaderProfile.KINDLE.formats) fail("usb_invalid_file")
            val operations = port.operations()?.toSet() ?: fail("usb_unsupported")
            if (!operations.containsAll(setOf(0x100C, 0x100D, 0x101B))) fail("usb_unsupported")
            val destination = destination(source.bytes)
            val name = (1..3).map { "brizfi-${newId()}.${source.extension}" }.firstOrNull { candidate ->
                destination.children.none { it.name.equals(candidate, ignoreCase = true) }
            } ?: fail("usb_transfer_failed")
            checkCancelled()
            phase("writing")
            creationStarted = true
            val created = port.create(destination.storage, destination.folder, name, source.bytes)
                ?: fail("usb_uncertain")
            // A malformed/reused response can never authorize deletion of an existing book.
            if (created.handle == 0 || created.handle == -1 || created.handle in existingHandles ||
                created.storage != destination.storage || created.parent != destination.folder ||
                created.format == FOLDER || created.name != name
            ) fail("usb_uncertain")
            own = created
            checkCancelled()
            if (!port.send(created.handle, source)) fail("usb_transfer_failed")
            checkCancelled()
            phase("verifying")
            val actual = port.info(created.handle) ?: fail("usb_verification_failed")
            if (actual.bytes != source.bytes || actual.bytes > UsbBookSource.MAX_BYTES ||
                actual.name != name || actual.storage != destination.storage || actual.parent != destination.folder ||
                actual.format == FOLDER
            ) fail("usb_verification_failed")
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(CHUNK)
            var offset = 0L
            var reads = 0
            while (offset < source.bytes) {
                checkCancelled()
                if (++reads > 1024) fail("usb_verification_failed")
                val length = minOf(CHUNK.toLong(), source.bytes - offset).toInt()
                val count = port.read(created.handle, offset, length, buffer)
                if (count <= 0 || count > length) fail("usb_verification_failed")
                digest.update(buffer, 0, count.toInt())
                offset += count
            }
            checkCancelled()
            if (!digest.digest().contentEquals(source.digest)) fail("usb_verification_failed")
            return Receipt(source.bytes, name)
        } catch (error: Exception) {
            val original = if (cancelled()) "usb_cancelled"
                else (error as? UsbTransferFailure)?.code ?: "usb_transfer_failed"
            if (own != null) {
                val objectInfo = own
                val removed = runCatching {
                    // Recheck identity immediately before deleting only the object this job created.
                    val current = port.info(objectInfo.handle)
                    current != null && current.name == objectInfo.name && current.storage == objectInfo.storage &&
                        current.parent == objectInfo.parent && current.format != FOLDER &&
                        port.delete(objectInfo.handle) &&
                        boundedHandles(objectInfo.storage, objectInfo.parent).none { it == objectInfo.handle }
                }.getOrDefault(false)
                if (!removed) fail("usb_uncertain")
            } else if (creationStarted) {
                fail("usb_uncertain")
            }
            fail(original)
        }
    }

    private fun destination(bytes: Long): Destination {
        val storages = port.storages() ?: fail("usb_unsupported")
        if (storages.isEmpty() || storages.size > 32) fail("usb_unsupported")
        var full = false
        for (storage in storages.distinct()) {
            checkCancelled()
            val free = port.freeBytes(storage) ?: fail("usb_unsupported")
            if (free < 0) fail("usb_unsupported")
            val roots = objects(storage, -1)
            for (folder in roots) {
                checkCancelled()
                if (folder.format != FOLDER || !folder.name.equals("documents", ignoreCase = true) ||
                    folder.parent != 0 || folder.storage != storage || folder.protection != 0
                ) continue
                if (free < bytes) { full = true; continue }
                return Destination(storage, folder.handle, objects(storage, folder.handle))
            }
        }
        fail(if (full) "usb_full" else "usb_documents_missing")
    }

    private fun objects(storage: Int, parent: Int) = boundedHandles(storage, parent).map { handle ->
        checkCancelled()
        existingHandles.add(handle)
        val info = port.info(handle) ?: fail("usb_unsupported")
        if (info.handle != handle || info.storage != storage || info.parent != (if (parent == -1) 0 else parent)) {
            fail("usb_unsupported")
        }
        info
    }

    private fun boundedHandles(storage: Int, parent: Int): IntArray {
        val handles = port.handles(storage, parent) ?: fail("usb_unsupported")
        visits += handles.size
        if (handles.size > 4096 || visits > 4096) fail("usb_unsupported")
        return handles
    }

    private fun checkCancelled() { if (cancelled()) fail("usb_cancelled") }
    private fun fail(code: String): Nothing = throw UsbTransferFailure(code)

    companion object {
        const val FOLDER = 0x3001
        private const val CHUNK = 64 * 1024
    }
}
