package ru.mkulkov.brizfi

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Local cache of a confirmed store entitlement. No book or payment data. */
object MonetizationPreferences {
    fun register(context: Context, messenger: BinaryMessenger) {
        val preferences = context.getSharedPreferences("monetization", Context.MODE_PRIVATE)
        MethodChannel(messenger, "ru.mkulkov.brizfi/monetization").setMethodCallHandler { call, result ->
            val key = if (call.argument<Boolean>("test") == true) "ads_removed_test" else "ads_removed"
            when (call.method) {
                "adsRemoved" -> result.success(preferences.getBoolean(key, false))
                "setAdsRemoved" -> {
                    if (preferences.edit().putBoolean(key, true).commit()) result.success(null)
                    else result.error("unavailable", "Preference storage unavailable", null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
