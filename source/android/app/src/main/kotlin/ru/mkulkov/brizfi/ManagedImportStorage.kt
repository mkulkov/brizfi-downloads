package ru.mkulkov.brizfi

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.UUID

/** App-owned copies only. All instances share a lock and conversion reservations. */
internal class ManagedImportStorage(
    private val root: File,
    private val now: () -> Long = System::currentTimeMillis,
    private val fileLimit: Long = 32L * 1024 * 1024,
    private val quota: Long = 96L * 1024 * 1024,
    private val expiryMillis: Long = 24L * 60 * 60 * 1000,
) {
    internal class Failure(val code: String) : IOException()
    private data class Reservation(val input: String, val baseline: Long)

    /** Copy the SAF stream without exposing or ever deleting its original. */
    fun importBook(name: String, openSource: () -> InputStream, cancelled: () -> Boolean): File =
        synchronized(lock) {
            if (!SharedBookPolicy.supportsName(name)) throw Failure("unsupported_format")
            ensureRoot()
            val occupied = accountedBytes()
            val directory = File(root, UUID.randomUUID().toString())
            if (!directory.mkdir()) throw Failure("storage_unavailable")
            val marker = File(directory, MARKER)
            try {
                marker.writeText("$VERSION\n${directory.name}\n")
                marker.setLastModified(now())
                val target = File(directory, name)
                if (target.parentFile != directory || name == MARKER) throw Failure("import_failed")
                val overhead = marker.length()
                if (occupied > quota - overhead) throw Failure("cache_full")
                val sourceStream = try { openSource() } catch (_: Exception) { throw Failure("import_failed") }
                sourceStream.use { source ->
                    target.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var total = 0L
                        while (true) {
                            if (cancelled()) throw Failure("import_failed")
                            val count = try { source.read(buffer) } catch (_: IOException) { throw Failure("import_failed") }
                            if (count < 0) break
                            total += count
                            if (total > fileLimit) throw Failure("too_large")
                            if (total > quota - occupied - overhead) throw Failure("cache_full")
                            output.write(buffer, 0, count)
                        }
                        if (total == 0L) throw Failure("invalid_file")
                    }
                }
                liveDirectories.add(directory.canonicalPath)
                target
            } catch (error: Exception) {
                // Only the new directory created in this call is rolled back.
                deleteTree(directory)
                if (error is Failure) throw error
                if (error is IOException || error is SecurityException) throw Failure("storage_unavailable")
                throw Failure("import_failed")
            }
        }

    /** Reserve one largest allowed output in addition to every cached variant. */
    fun reserveConversion(path: String) = synchronized(lock) {
        ensureRoot()
        val directory = ownedDirectory(path)
        val input = checkedFile(path)
        if (!input.isFile || input.name == MARKER || input.parentFile != directory) {
            throw Failure("import_failed")
        }
        val key = directory.canonicalPath
        if (reservations.containsKey(key)) throw Failure("busy")
        val baseline = treeBytes(directory)
        if (accountedBytes() > quota - fileLimit) throw Failure("cache_full")
        reservations[key] = Reservation(input.canonicalPath, baseline)
        liveDirectories.add(key)
        File(directory, MARKER).setLastModified(now())
    }

    /** Call only once native work and any discarded-output cleanup have ended. */
    fun finishConversion(path: String) = synchronized(lock) {
        ensureRoot()
        val directory = ownedDirectory(path)
        val key = directory.canonicalPath
        val reservation = reservations[key]
        if (reservation != null && reservation.input != checkedFile(path).canonicalPath) {
            throw Failure("busy")
        }
        // Even failed conversion must release its reservation, preserving the input.
        reservations.remove(key)
        File(directory, MARKER).setLastModified(now())
        val input = checkedFile(path)
        val outputs = listOf("azw3", "epub").map { File("${input.path}.converted.$it") }
        if (outputs.any { it.exists() && treeBytes(it) > fileLimit } || accountedBytes() > quota) {
            throw Failure("cache_full")
        }
    }

    /** Release one marked direct UUID child, after its conversion/server use ends. */
    fun releaseImport(path: String) = synchronized(lock) {
        ensureRoot()
        val directory = ownedDirectory(path)
        val key = directory.canonicalPath
        if (reservations.containsKey(key)) throw Failure("busy")
        treeBytes(directory) // Reject symlinks or unreadable structure before deleting.
        deleteTree(directory)
        if (directory.exists()) throw Failure("storage_unavailable")
        liveDirectories.remove(key)
    }

    /** Startup/manual collection never evicts fresh, live, reserved or legacy copies. */
    fun clearExpiredImports() = synchronized(lock) {
        ensureRoot()
        treeBytes(root) // Bound and validate the whole scan before any cleanup.
        val cutoff = now() - expiryMillis
        children(root).forEach { directory ->
            if (isOwnedDirectory(directory)) {
                val key = directory.canonicalPath
                if (key !in liveDirectories && key !in reservations &&
                    File(directory, MARKER).lastModified() < cutoff
                ) {
                    treeBytes(directory)
                    deleteTree(directory)
                    if (directory.exists()) throw Failure("storage_unavailable")
                }
            }
        }
    }

    private fun ensureRoot() {
        try {
            if (Files.isSymbolicLink(root.toPath()) || root.canonicalFile != root.absoluteFile) {
                throw Failure("storage_unavailable")
            }
            if ((!root.exists() && !root.mkdirs()) || !root.isDirectory) {
                throw Failure("storage_unavailable")
            }
        } catch (_: IOException) {
            throw Failure("storage_unavailable")
        }
    }

    private fun ownedDirectory(path: String): File {
        val candidate = checkedFile(path)
        val directory = if (candidate.parentFile == root) candidate else candidate.parentFile
        if (directory == null || !isOwnedDirectory(directory)) throw Failure("import_failed")
        return directory
    }

    private fun checkedFile(path: String): File {
        val file = File(path)
        if (!file.isAbsolute || Files.isSymbolicLink(file.toPath()) || file.canonicalFile != file.absoluteFile) {
            throw Failure("import_failed")
        }
        return file
    }

    private fun isOwnedDirectory(directory: File): Boolean {
        if (directory.parentFile != root || Files.isSymbolicLink(directory.toPath()) ||
            directory.canonicalFile != directory.absoluteFile || !directory.isDirectory
        ) return false
        if (runCatching { UUID.fromString(directory.name).toString() }.getOrNull() != directory.name) return false
        val marker = File(directory, MARKER)
        return marker.isFile && !Files.isSymbolicLink(marker.toPath()) && marker.length() <= 128 &&
            marker.readText() == "$VERSION\n${directory.name}\n"
    }

    private fun accountedBytes(): Long {
        val visits = intArrayOf(0)
        return children(root).fold(0L) { total, child ->
            val actual = treeBytes(child, visits = visits)
            val reserved = reservations[child.canonicalPath]?.let { it.baseline + fileLimit } ?: 0L
            val bytes = maxOf(actual, reserved)
            if (total > Long.MAX_VALUE - bytes) throw Failure("storage_unavailable")
            total + bytes
        }
    }

    private fun treeBytes(file: File, depth: Int = 0, visits: IntArray = intArrayOf(0)): Long {
        visits[0]++
        if (visits[0] > MAX_ENTRIES || depth > 32 || Files.isSymbolicLink(file.toPath()) ||
            file.canonicalFile != file.absoluteFile
        ) throw Failure("storage_unavailable")
        if (file.isFile) return file.length()
        if (!file.isDirectory) throw Failure("storage_unavailable")
        return children(file).fold(0L) { total, child ->
            val bytes = treeBytes(child, depth + 1, visits)
            if (total > Long.MAX_VALUE - bytes) throw Failure("storage_unavailable")
            total + bytes
        }
    }

    private fun children(file: File): Array<File> {
        val entries = file.listFiles() ?: throw Failure("storage_unavailable")
        if (entries.size > MAX_ENTRIES) throw Failure("storage_unavailable")
        return entries
    }

    private fun deleteTree(file: File) {
        // File.delete removes a link itself; never traverse a link during rollback.
        if (!Files.isSymbolicLink(file.toPath()) && file.isDirectory) {
            children(file).forEach { deleteTree(it) }
        }
        if (!file.delete() && file.exists()) throw Failure("storage_unavailable")
    }

    companion object {
        private const val MARKER = ".brizfi_owned"
        private const val VERSION = "brizfi-import-v1"
        private const val MAX_ENTRIES = 4096
        private val lock = Any()
        private val reservations = mutableMapOf<String, Reservation>()
        private val liveDirectories = mutableSetOf<String>()
    }
}
