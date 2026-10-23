package ru.mkulkov.brizfi

import java.io.File

/** Only owns copies made for this result until they have been delivered to Dart. */
internal class PickerImportBatch(private val storage: ManagedImportStorage) {
    private val copies = mutableListOf<File>()
    private var delivered = false

    fun copy(uris: List<String>, copyBook: (String) -> File, cancelled: () -> Boolean): List<File> {
        for (uri in uris) {
            if (cancelled()) throw ManagedImportStorage.Failure("cancelled")
            copies.add(copyBook(uri))
            if (cancelled()) throw ManagedImportStorage.Failure("cancelled")
        }
        return copies.toList()
    }

    @Synchronized fun delivered() { delivered = true }

    // Runs on the same serial importer as copy(), including the teardown task.
    @Synchronized fun rollback() {
        if (delivered) return
        val iterator = copies.iterator()
        while (iterator.hasNext()) {
            try {
                storage.releaseImport(iterator.next().absolutePath)
                iterator.remove()
            } catch (_: Exception) { /* A later teardown/TTL cleanup can retry an unavailable store. */ }
        }
    }
}
