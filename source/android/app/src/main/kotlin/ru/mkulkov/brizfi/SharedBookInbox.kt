package ru.mkulkov.brizfi

import java.net.URI

/** Pure share validation; provider streams are opened only by the existing importer. */
internal object SharedBookPolicy {
    val extensions = setOf("epub", "fb2", "azw3", "mobi", "pdf", "txt")
    const val SEND = "android.intent.action.SEND"
    const val SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
    const val MAX_CLIP_ITEMS = 32
    val mimeTypes = setOf(
        "application/epub+zip", "application/x-fictionbook+xml", "application/xml",
        "text/xml", "application/vnd.amazon.mobi8-ebook", "application/octet-stream",
        "application/x-mobipocket-ebook", "application/pdf", "text/plain",
    )

    fun supportsName(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) in extensions

    sealed class Selection {
        data class Book(val uri: String) : Selection()
        data class Rejected(val code: String) : Selection()
    }

    fun select(
        action: String?, mimeType: String?, stream: String?, clipUris: List<String>,
        malformed: Boolean = false,
    ): Selection? {
        if (action == SEND_MULTIPLE) return Selection.Rejected("multiple_books")
        if (action != SEND) return null
        if (malformed || clipUris.size > MAX_CLIP_ITEMS) return Selection.Rejected("invalid_share")
        val candidates = (listOfNotNull(stream) + clipUris).distinct()
        if (candidates.size > 1) return Selection.Rejected("multiple_books")
        val candidate = candidates.singleOrNull() ?: return Selection.Rejected("invalid_share")
        val uri = runCatching { URI(candidate) }.getOrNull()
        if (uri == null || uri.scheme != "content" || uri.rawAuthority.isNullOrEmpty() || uri.isOpaque) {
            return Selection.Rejected("invalid_share")
        }
        if (mimeType !in mimeTypes) return Selection.Rejected("unsupported_format")
        return Selection.Book(candidate)
    }
}

/** Main-thread owned single slot. Never overwrites a waiting book or an active copy. */
internal class SharedBookInbox {
    private var pending: SharedBookPolicy.Selection? = null
    var copying = false
        private set

    sealed class Take {
        data object Empty : Take()
        data object Busy : Take()
        data class Ready(val selection: SharedBookPolicy.Selection) : Take()
    }

    fun offer(selection: SharedBookPolicy.Selection): Boolean {
        if (pending != null || copying) return false
        pending = selection
        return true
    }

    fun take(pickerBusy: Boolean): Take {
        if (copying || pickerBusy) return Take.Busy
        val selection = pending ?: return Take.Empty
        pending = null
        copying = selection is SharedBookPolicy.Selection.Book
        return Take.Ready(selection)
    }

    fun finishCopy() { copying = false }
}
