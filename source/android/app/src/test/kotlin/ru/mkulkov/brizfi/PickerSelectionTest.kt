package ru.mkulkov.brizfi

import org.junit.Assert.*
import org.junit.Test

class PickerSelectionTest {
    private fun uri(index: Int) = "content://books/book/$index"
    private fun select(data: String? = null, clips: List<String?> = emptyList(), multiple: Boolean = true) =
        PickerSelection.select(true, data, clips, multiple)

    @Test fun cancellationIgnoresAnyReturnedPayload() {
        assertEquals(PickerSelection.Selection.Cancelled, PickerSelection.select(false, "file:///bad", listOf(null), true))
    }

    @Test fun nullSuccessfulPayloadIsRejected() {
        assertEquals(PickerSelection.Selection.Rejected("invalid_selection"), select())
    }

    @Test fun singleDataAndClipFallbackRetainSingleContract() {
        assertEquals(PickerSelection.Selection.Books(listOf(uri(1))), select(uri(1), multiple = false))
        assertEquals(PickerSelection.Selection.Books(listOf(uri(1))), select(clips = listOf(uri(1)), multiple = false))
        assertEquals(PickerSelection.Selection.Rejected("too_many_books"), select(clips = listOf(uri(1), uri(2)), multiple = false))
    }

    @Test fun multipleAndDuplicatesKeepProviderOrder() {
        assertEquals(PickerSelection.Selection.Books(listOf(uri(1), uri(2))), select(uri(1), listOf(uri(1), uri(2), uri(2))))
    }

    @Test fun tenDistinctBooksAreAllowedAndElevenRejected() {
        assertEquals(PickerSelection.Selection.Books((1..10).map(::uri)), select(clips = (1..10).map(::uri)))
        assertEquals(PickerSelection.Selection.Rejected("too_many_books"), select(clips = (1..11).map(::uri)))
    }

    @Test fun rawClipLimitIsBoundedBeforeDeduplication() {
        assertEquals(PickerSelection.Selection.Books(listOf(uri(1))), select(clips = List(32) { uri(1) }))
        assertEquals(PickerSelection.Selection.Rejected("too_many_books"), select(clips = List(33) { uri(1) }))
    }

    @Test fun malformedAndNonContentUrisRejectWholeSelection() {
        for (invalid in listOf(null, "file:///book.epub", "https://books/book", "content:book", "content:///book", "content://books/bad%", "content://books/space here", "content://books/book#fragment")) {
            assertEquals(PickerSelection.Selection.Rejected("invalid_selection"), select(uri(1), listOf(invalid)))
        }
    }
}
