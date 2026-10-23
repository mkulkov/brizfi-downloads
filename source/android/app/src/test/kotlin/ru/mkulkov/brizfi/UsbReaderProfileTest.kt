package ru.mkulkov.brizfi

import org.junit.Assert.*
import org.junit.Test

class UsbReaderProfileTest {
    private val nook = UsbReaderProfile.NOOK
    private val external = UsbReaderProfile.EXTERNAL_AUTHORITY
    private val volume = UsbSafFolderPolicy.Volume("1234-ABCD", true, false, true)

    @Test fun hardwareAllowlistDoesNotInferProfilesFromVendorAlone() {
        assertEquals(UsbReaderProfile.KINDLE, UsbReaderProfile.forUsb(0x1949, 0x9981))
        assertEquals(nook, UsbReaderProfile.forUsb(0x2080, 0x0003))
        assertNull(UsbReaderProfile.forUsb(0x1949, 0x1234))
        assertNull(UsbReaderProfile.forUsb(0x2080, 0x0004))
        assertNull(UsbReaderProfile.forUsb(0x1234, 0x9981))
        assertEquals(setOf("epub", "pdf"), nook.formats)
        assertEquals(setOf("azw3", "mobi", "pdf", "txt"), UsbReaderProfile.KINDLE.formats)
        assertTrue(nook.usesSystemStorage)
        assertFalse(UsbReaderProfile.KINDLE.usesSystemStorage)
    }

    @Test fun nookRequiresExactExistingBooksPathOnMountedRemovableVolume() {
        assertTrue(UsbSafFolderPolicy.accepts(nook, external, "1234-abcd:My Files/Books", listOf(volume)))
        for (id in listOf("primary:My Files/Books", "1234-ABCD:", "1234-ABCD:Books", "1234-ABCD:My Files",
            "1234-ABCD:My Files/Documents", "1234-ABCD:My Files/Books/child", "1234-ABCD:My Files/../Books",
            "1234-ABCD:my files/books", "raw:/storage/1234-ABCD/My Files/Books")) {
            assertFalse(id, UsbSafFolderPolicy.accepts(nook, external, id, listOf(volume)))
        }
        assertFalse(UsbSafFolderPolicy.accepts(nook, external, "1234-ABCD:My Files/Books", emptyList()))
        for (bad in listOf(volume.copy(removable = false), volume.copy(primary = true), volume.copy(mounted = false), volume.copy(uuid = null))) {
            assertFalse(UsbSafFolderPolicy.accepts(nook, external, "1234-ABCD:My Files/Books", listOf(bad)))
        }
        assertFalse(UsbSafFolderPolicy.accepts(nook, external, "1234-ABCD:My Files/Books", listOf(volume, volume)))
    }

    @Test fun cloudDownloadsAndMtpAuthoritiesCannotAuthorizeNookWrites() {
        for (authority in listOf(null, "com.android.providers.downloads.documents", "cloud.provider", UsbReaderProfile.MTP_AUTHORITY)) {
            assertFalse(UsbSafFolderPolicy.accepts(nook, authority, "1234-ABCD:My Files/Books", listOf(volume)))
        }
        assertFalse(UsbSafFolderPolicy.accepts(UsbReaderProfile.KINDLE, external, "1234-ABCD:My Files/Books", listOf(volume)))
        assertTrue(UsbSafFolderPolicy.accepts(UsbReaderProfile.KINDLE, UsbReaderProfile.MTP_AUTHORITY, "opaque-id", emptyList()))
        assertTrue(UsbSafFolderPolicy.folderName(nook, "Books"))
        assertFalse(UsbSafFolderPolicy.folderName(nook, "documents"))
        assertTrue(UsbSafFolderPolicy.folderName(UsbReaderProfile.KINDLE, "DOCUMENTS"))
    }
    @Test fun genericStorageAcceptsChosenRootOrFolderOnlyOnMountedRemovableVolume() {
        val generic = UsbReaderProfile.GENERIC_STORAGE
        for (id in listOf("1234-ABCD:", "1234-ABCD:Books", "1234-ABCD:My Books/Read")) {
            assertTrue(id, UsbSafFolderPolicy.accepts(generic, external, id, listOf(volume)))
        }
        for (id in listOf("primary:Books", "1234-ABCD:../Books", "1234-ABCD:Books/..", "1234-ABCD:/Books",
                "1234-ABCD:Books//Read", "1234-ABCD:Books\\Read", "1234-ABCD:Books:")) {
            assertFalse(id, UsbSafFolderPolicy.accepts(generic, external, id, listOf(volume)))
        }
        for (bad in listOf(volume.copy(primary = true), volume.copy(removable = false), volume.copy(mounted = false))) {
            assertFalse(UsbSafFolderPolicy.accepts(generic, external, "1234-ABCD:Books", listOf(bad)))
        }
        assertFalse(UsbSafFolderPolicy.accepts(generic, external, "1234-ABCD:", emptyList()))
        assertTrue(generic.usesSaf)
        assertTrue(generic.usesSystemStorage)
    }

    @Test fun genericStorageChildIdsCannotEscapeTheChosenTree() {
        assertTrue(UsbSafFolderPolicy.storageDocumentId("1234-ABCD:", "1234-ABCD:book.epub"))
        assertTrue(UsbSafFolderPolicy.storageDocumentId("1234-ABCD:Books", "1234-ABCD:Books/book.epub"))
        for (id in listOf("1234-ABCD:Books/../book", "1234-ABCD:Books/..", "1234-ABCD:Books/sub/book",
                "1234-ABCD:Other/book", "primary:Books/book", "1234-ABCD:Books/", "1234-ABCD:Books/evil\\book")) {
            assertFalse(id, UsbSafFolderPolicy.storageDocumentId("1234-ABCD:Books", id))
        }
    }

    @Test fun genericMtpUsesSafAndAcceptsSelectedFolderName() {
        val generic = UsbReaderProfile.GENERIC_MTP
        assertTrue(generic.usesSaf)
        assertFalse(generic.usesSystemStorage)
        assertTrue(UsbSafFolderPolicy.accepts(generic, UsbReaderProfile.MTP_AUTHORITY, "opaque-id", emptyList()))
        assertFalse(UsbSafFolderPolicy.accepts(generic, external, "opaque-id", emptyList()))
        assertTrue(UsbSafFolderPolicy.folderName(generic, "My Books"))
        assertFalse(UsbSafFolderPolicy.folderName(generic, " "))
        assertFalse(UsbSafFolderPolicy.folderName(generic, "bad\u0000name"))
    }
}
