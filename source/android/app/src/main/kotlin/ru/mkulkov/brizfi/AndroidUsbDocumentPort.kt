package ru.mkulkov.brizfi

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import java.io.InputStream
import java.io.OutputStream

/** Android's MTP provider retains the USB interface while serving this authorized SAF tree. */
internal class AndroidUsbDocumentPort(
    private val resolver: ContentResolver,
    private val tree: Uri,
    private val profile: UsbReaderProfile = UsbReaderProfile.KINDLE,
    private val validateDestination: () -> Unit = {},
) : UsbDocumentPort {
    private val rootId: String

    init {
        if (tree.scheme != "content" || tree.authority != profile.authority || tree.query != null ||
            tree.fragment != null || !DocumentsContract.isTreeUri(tree)
        ) throw UsbTransferFailure("usb_unsupported")
        rootId = runCatching { DocumentsContract.getTreeDocumentId(tree) }
            .getOrNull()?.takeIf { basicId(it) } ?: throw UsbTransferFailure("usb_unsupported")
        validateDestination()
    }

    override fun folder(): UsbDocumentPort.Document =
        info(rootId) ?: throw UsbTransferFailure("usb_documents_missing")

    override fun children(): List<UsbDocumentPort.Document> = query(
        DocumentsContract.buildChildDocumentsUriUsingTree(tree, rootId),
        UsbDocumentTransfer.MAX_CHILDREN,
    )

    override fun info(id: String): UsbDocumentPort.Document? {
        val rows = query(uri(id), 1)
        val result = rows.singleOrNull() ?: return null
        if (result.id != id) throw UsbTransferFailure("usb_unsupported")
        return result
    }

    override fun create(name: String): UsbDocumentPort.Document? {
        if (!NAME.matches(name) || name.substringAfterLast('.') !in profile.formats) throw UsbTransferFailure("usb_invalid_file")
        val mime = when (name.substringAfterLast('.')) {
            "epub" -> "application/epub+zip"
            "pdf" -> "application/pdf"
            "txt" -> "text/plain"
            else -> "application/octet-stream"
        }
        val created = DocumentsContract.createDocument(resolver, uri(rootId), mime, name)
            ?: return null
        if (created.scheme != "content" || created.authority != profile.authority || created.query != null ||
            created.fragment != null || !DocumentsContract.isTreeUri(created) ||
            DocumentsContract.getTreeDocumentId(created) != rootId
        ) throw UsbTransferFailure("usb_uncertain")
        return info(DocumentsContract.getDocumentId(created))
    }

    override fun openWrite(id: String): UsbDocumentPort.WriteHandle {
        val descriptor = resolver.openFileDescriptor(uri(id), "w")
            ?: throw UsbTransferFailure("usb_transfer_failed")
        val output = ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
        return object : UsbDocumentPort.WriteHandle {
            override val output: OutputStream = output
            override fun sync() {
                output.flush()
                // MtpDocumentsProvider's proxy flushes at fsync; release alone hides upload errors.
                descriptor.fileDescriptor.sync()
                descriptor.checkError()
            }
            override fun close() { output.close() }
        }
    }

    override fun openRead(id: String): InputStream = resolver.openInputStream(uri(id))
        ?: throw UsbTransferFailure("usb_verification_failed")

    override fun delete(id: String): Boolean = DocumentsContract.deleteDocument(resolver, uri(id))

    private fun uri(id: String): Uri {
        validateDestination()
        if (!validId(id)) throw UsbTransferFailure("usb_unsupported")
        return DocumentsContract.buildDocumentUriUsingTree(tree, id)
    }

    private fun query(uri: Uri, limit: Int): List<UsbDocumentPort.Document> {
        // The MTP provider initially returns only part of a directory. Its active loader can
        // also remove a new DB entry, so creation must wait for enumeration to finish.
        val deadline = System.nanoTime() + 15_000_000_000L
        repeat(150) {
            validateDestination()
            val cursor = resolver.query(uri, COLUMNS, null, null, null)
                ?: throw UsbTransferFailure("usb_transfer_failed")
            cursor.use {
                if (cursor.extras.getString(DocumentsContract.EXTRA_ERROR) != null) {
                    throw UsbTransferFailure("usb_transfer_failed")
                }
                if (!cursor.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) {
                    return readRows(cursor, limit)
                }
            }
            if (System.nanoTime() >= deadline) throw UsbTransferFailure("usb_transfer_failed")
            Thread.sleep(100)
        }
        throw UsbTransferFailure("usb_transfer_failed")
    }

    private fun readRows(cursor: android.database.Cursor, limit: Int): List<UsbDocumentPort.Document> {
        val result = mutableListOf<UsbDocumentPort.Document>()
        val id = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
        val name = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val mime = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
        val flags = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_FLAGS)
        val size = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
        while (cursor.moveToNext()) {
            if (result.size >= limit) throw UsbTransferFailure("usb_unsupported")
            val documentId = cursor.getString(id)
            val displayName = cursor.getString(name)
            val byteCount = if (cursor.isNull(size)) null else cursor.getLong(size)
            if (documentId == null || !validId(documentId) || displayName == null ||
                displayName.length > 1024 || (byteCount != null && byteCount < 0)
            ) throw UsbTransferFailure("usb_unsupported")
            val capability = cursor.getLong(flags)
            result.add(UsbDocumentPort.Document(
                documentId, displayName, byteCount,
                cursor.getString(mime) == DocumentsContract.Document.MIME_TYPE_DIR,
                capability and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L,
                capability and DocumentsContract.Document.FLAG_SUPPORTS_WRITE.toLong() != 0L,
                capability and DocumentsContract.Document.FLAG_SUPPORTS_DELETE.toLong() != 0L,
            ))
        }
        if (result.map { it.id }.toSet().size != result.size) throw UsbTransferFailure("usb_unsupported")
        return result
    }

    private fun validId(id: String): Boolean {
        if (!basicId(id)) return false
        if (!profile.usesSystemStorage) return true
        return UsbSafFolderPolicy.storageDocumentId(rootId, id)
    }

    companion object {
        internal const val AUTHORITY = "com.android.mtp.documents"
        private val NAME = Regex("brizfi-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.(azw3|mobi|epub|pdf|txt)")
        private val COLUMNS = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        private fun basicId(id: String) = id.isNotEmpty() && id.length <= 1024 && '\u0000' !in id
    }
}
