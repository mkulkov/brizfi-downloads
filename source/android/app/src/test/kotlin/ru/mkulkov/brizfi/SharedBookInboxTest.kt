package ru.mkulkov.brizfi

import org.junit.Assert.*
import org.junit.Test

class SharedBookInboxTest {
    private val uri = "content://books/document/one.epub"
    private val second = "content://books/document/two.epub"
    private val book = SharedBookPolicy.Selection.Book(uri)

    private fun select(
        stream: String? = uri, clips: List<String> = emptyList(),
        mime: String? = "application/epub+zip", malformed: Boolean = false,
        action: String? = SharedBookPolicy.SEND,
    ) = SharedBookPolicy.select(action, mime, stream, clips, malformed)

    private fun rejected(code: String, selection: SharedBookPolicy.Selection?) {
        assertEquals(SharedBookPolicy.Selection.Rejected(code), selection)
    }

    @Test fun supportedMimeTypesAcceptOneContentStream() {
        listOf("application/epub+zip", "application/x-fictionbook+xml", "application/xml",
            "text/xml", "application/vnd.amazon.mobi8-ebook", "application/octet-stream",
            "application/x-mobipocket-ebook", "application/pdf", "text/plain").forEach {
            assertEquals(book, select(mime = it))
        }
    }

    @Test fun clipDataIsTheFallbackWhenExtraStreamIsAbsent() {
        assertEquals(book, select(stream = null, clips = listOf(uri)))
    }

    @Test fun duplicateExtraAndClipUriCountAsOneBook() {
        assertEquals(book, select(clips = listOf(uri, uri)))
    }

    @Test fun clipItemCountIsBoundedEvenWhenAllUrisAreDuplicates() {
        assertEquals(book, select(clips = List(SharedBookPolicy.MAX_CLIP_ITEMS) { uri }))
        rejected("invalid_share", select(clips = List(SharedBookPolicy.MAX_CLIP_ITEMS + 1) { uri }))
    }

    @Test fun differentExtraAndClipUrisAreRejected() {
        rejected("multiple_books", select(clips = listOf(second)))
    }

    @Test fun multipleClipUrisAreRejected() {
        rejected("multiple_books", select(stream = null, clips = listOf(uri, second)))
    }

    @Test fun sendMultipleIsAlwaysRejectedEvenForSingleOrMalformedItem() {
        rejected("multiple_books", select(action = SharedBookPolicy.SEND_MULTIPLE))
        rejected("multiple_books", select(action = SharedBookPolicy.SEND_MULTIPLE, malformed = true))
    }

    @Test fun normalLaunchIsIgnored() {
        assertNull(select(action = "android.intent.action.MAIN"))
        assertNull(select(action = null))
    }

    @Test fun absentStreamOrTextOnlyShareIsRejected() {
        rejected("invalid_share", select(stream = null))
        rejected("invalid_share", select(stream = null, mime = "text/plain"))
    }

    @Test fun malformedParcelableOrNonUriClipItemIsRejected() {
        rejected("invalid_share", select(malformed = true))
    }

    @Test fun unsupportedMimeIsRejectedEvenWithValidStream() {
        rejected("unsupported_format", select(mime = "image/png"))
        rejected("unsupported_format", select(mime = "text/html"))
        rejected("unsupported_format", select(mime = null))
    }

    @Test fun displayNameExtensionDeterminesSupportedOriginal() {
        listOf("epub", "fb2", "azw3", "mobi", "pdf", "txt").forEach {
            assertTrue(SharedBookPolicy.supportsName("Книга.$it"))
            assertTrue(SharedBookPolicy.supportsName("BOOK.${it.uppercase()}"))
        }
        listOf("book", "book.zip", "book.epub.exe", "book.txt ").forEach {
            assertFalse(SharedBookPolicy.supportsName(it))
        }
    }

    @Test fun externalUrlsFileUrisAndRawPathsAreRejected() {
        listOf("https://books.test/book.epub", "file:///books/one.epub", "/books/one.epub",
            "content:one.epub", "content:///one.epub", "content://[broken").forEach {
            rejected("invalid_share", select(stream = it))
        }
    }

    @Test fun emptyInboxReturnsNone() {
        assertEquals(SharedBookInbox.Take.Empty, SharedBookInbox().take(pickerBusy = false))
    }

    @Test fun firstPendingBookIsNeverOverwritten() {
        val inbox = SharedBookInbox()
        assertTrue(inbox.offer(book))
        assertFalse(inbox.offer(SharedBookPolicy.Selection.Book(second)))
        assertEquals(SharedBookInbox.Take.Ready(book), inbox.take(pickerBusy = false))
    }

    @Test fun pickerDefersConsumptionWithoutDroppingShare() {
        val inbox = SharedBookInbox()
        assertTrue(inbox.offer(book))
        assertEquals(SharedBookInbox.Take.Busy, inbox.take(pickerBusy = true))
        assertEquals(SharedBookInbox.Take.Ready(book), inbox.take(pickerBusy = false))
    }

    @Test fun copyingBlocksFurtherTakeAndOfferUntilCompletion() {
        val inbox = SharedBookInbox()
        inbox.offer(book)
        inbox.take(pickerBusy = false)
        assertTrue(inbox.copying)
        assertEquals(SharedBookInbox.Take.Busy, inbox.take(pickerBusy = false))
        assertFalse(inbox.offer(SharedBookPolicy.Selection.Book(second)))
        inbox.finishCopy()
        assertFalse(inbox.copying)
        assertEquals(SharedBookInbox.Take.Empty, inbox.take(pickerBusy = false))
        assertTrue(inbox.offer(SharedBookPolicy.Selection.Book(second)))
    }

    @Test fun rejectedShareIsConsumedOnceWithoutStartingCopy() {
        val inbox = SharedBookInbox()
        val rejection = SharedBookPolicy.Selection.Rejected("multiple_books")
        assertTrue(inbox.offer(rejection))
        assertEquals(SharedBookInbox.Take.Ready(rejection), inbox.take(pickerBusy = false))
        assertFalse(inbox.copying)
        assertEquals(SharedBookInbox.Take.Empty, inbox.take(pickerBusy = false))
        assertTrue(inbox.offer(book))
    }
}
