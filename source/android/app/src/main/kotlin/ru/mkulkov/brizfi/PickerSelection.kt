package ru.mkulkov.brizfi

import java.net.URI

/** Validates the whole SAF result before any managed copy is created. */
internal object PickerSelection {
    const val MAX_BOOKS = 10
    const val MAX_CLIP_ITEMS = 32
    sealed class Selection {
        data object Cancelled : Selection()
        data class Books(val uris: List<String>) : Selection()
        data class Rejected(val code: String) : Selection()
    }

    fun select(ok: Boolean, data: String?, clips: List<String?>, multiple: Boolean): Selection {
        if (!ok) return Selection.Cancelled
        if (clips.size > MAX_CLIP_ITEMS) return Selection.Rejected("too_many_books")
        val candidates = listOfNotNull(data) + clips
        if (candidates.isEmpty()) return Selection.Rejected("invalid_selection")
        val unique = linkedSetOf<String>()
        for (value in candidates) {
            val uri = value?.let { runCatching { URI(it) }.getOrNull() }
            if (uri == null || !uri.scheme.equals("content", true) ||
                uri.isOpaque || uri.rawAuthority.isNullOrBlank() || uri.rawPath.isNullOrEmpty() ||
                uri.rawFragment != null || uri.rawUserInfo != null
            ) return Selection.Rejected("invalid_selection")
            unique.add(requireNotNull(value))
            if (unique.size > MAX_BOOKS || (!multiple && unique.size > 1)) {
                return Selection.Rejected("too_many_books")
            }
        }
        return Selection.Books(unique.toList())
    }
}
