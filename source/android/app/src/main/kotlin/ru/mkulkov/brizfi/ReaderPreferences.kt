package ru.mkulkov.brizfi

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Local reader-brand choices; keys are opaque hashes, never USB serials. */
internal object ReaderPreferences {
    private val brands = setOf("kindle", "nook", "kobo", "pocketbook", "onyx", "other")
    private val keyPattern = Regex("[A-Za-z0-9:_-]{1,160}")

    fun register(context: Context, messenger: BinaryMessenger) {
        val preferences = context.getSharedPreferences("reader_preferences", Context.MODE_PRIVATE)
        MethodChannel(messenger, "ru.mkulkov.brizfi/reader_preferences").setMethodCallHandler { call, result ->
            try {
                val saved = preferences.all.entries.asSequence()
                    .filter { keyPattern.matches(it.key) && it.value is String && it.value in brands }
                    .take(128).associate { it.key to it.value as String }
                when (call.method) {
                    "read" -> result.success(saved)
                    "write" -> {
                        val args = call.arguments as? Map<*, *>
                        val key = args?.get("key") as? String
                        val brand = args?.get("brand") as? String
                        if (key == null || !keyPattern.matches(key) || brand !in brands) {
                            result.error("invalid_arguments", "Invalid reader preference", null)
                        } else if (key !in saved && saved.size >= 128) {
                            result.error("preferences_full", "Reader preference limit reached", null)
                        } else if (preferences.edit().putString(key, brand).commit()) result.success(null)
                        else result.error("unavailable", "Preference storage unavailable", null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("unavailable", "Preference storage unavailable", null)
            }
        }
    }
}
