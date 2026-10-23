package xyz.chaosinc.cascade.android.data

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/**
 * The app's preferences, under the same key names and value formats as the
 * desktop store and the Apple apps (`cascade.<desktop key>`), so settings can
 * move between them. Plain values only: the token and proxy headers live in
 * SecureStore, never here.
 */
class Settings(context: Context) {
    val prefs: SharedPreferences = context.getSharedPreferences("cascade", Context.MODE_PRIVATE)
    /** Kept out of backup and device transfer (res/xml), so a restored phone gets its own id. */
    private val devicePrefs: SharedPreferences = context.getSharedPreferences("cascade.device", Context.MODE_PRIVATE)

    fun string(key: String): String? = prefs.getString(key, null)
    fun putString(key: String, value: String?) = prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()

    fun bool(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    fun putBool(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()

    /** Untyped, for values a reader validates itself (a stored value is untrusted). */
    fun raw(key: String): Any? = prefs.all[key]

    fun putInt(key: String, value: Int) = prefs.edit().putInt(key, value).apply()

    /** String lists are stored as one JSON-free line per id, which no Jellyfin id contains. */
    fun stringList(key: String): List<String>? = prefs.getString(key, null)?.split("\n")?.filter { it.isNotEmpty() }
    fun putStringList(key: String, value: List<String>) = prefs.edit().putString(key, value.joinToString("\n")).apply()

    fun remove(vararg keys: String) = prefs.edit().apply { keys.forEach(::remove) }.apply()

    /**
     * Unique per install. A constant would make every Cascade look like the
     * same device to the server, so remote control could not target one of
     * them and two installs would collide in the session list. A restored
     * or transferred backup must not carry it either, for the same reason.
     */
    val deviceId: String
        get() = devicePrefs.getString(DEVICE_ID, null)
            ?: UUID.randomUUID().toString().also { devicePrefs.edit().putString(DEVICE_ID, it).apply() }

    companion object {
        const val DEVICE_ID = "cascade.deviceId"
        const val SERVER_URL = "cascade.serverUrl"
        const val USER_ID = "cascade.userId"
        const val USERNAME = "cascade.username"
        const val LIBRARY_IDS = "cascade.libraryIds"
        const val SERVER_ONLY_LYRICS = "cascade.serverOnlyLyrics"
        const val REPEAT = "cascade.repeat"
        const val SPOTIFY_LINKS = "cascade.spotifyLinks"
    }
}
