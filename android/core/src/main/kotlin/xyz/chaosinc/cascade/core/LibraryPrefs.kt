package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put

/**
 * One browsing screen's sort and filter, persisted as `cascade.<view>Prefs` in
 * the desktop's shape (src/core/library-browse.ts LibraryPrefs): a JSON object
 * with field, dir ("asc" or "desc"), favorite, genre (a name), decade and
 * played ("played", "unplayed" or null). Keeping the shape means a value
 * written by any of the apps reads in the others.
 *
 * The field is held as the string it is stored as, because which fields are
 * allowed is each screen's own list.
 */
data class LibraryPrefs(
    val field: String = "name",
    val direction: SortDirection = SortDirection.Ascending,
    val filter: BrowseFilter = BrowseFilter(),
) {
    /** The desktop's JSON, with nulls where it has them, keys sorted. */
    val stored: String
        get() = buildJsonObject {
            put("decade", filter.decade?.let { JsonPrimitive(it) } ?: JsonNull)
            put("dir", if (direction == SortDirection.Descending) "desc" else "asc")
            put("favorite", filter.favoritesOnly)
            put("field", this@LibraryPrefs.field)
            put("genre", filter.genre?.let { JsonPrimitive(it) } ?: JsonNull)
            put("played", if (filter.played == BrowseFilter.Played.Any) JsonNull else JsonPrimitive(filter.played.raw))
        }.toString()

    companion object {
        /**
         * The stored text, back into prefs. The store is untrusted: bad JSON, a
         * non-object, a direction that is not asc or desc, a non-numeric decade
         * or an unknown played value each fall back to the default for that one
         * part. Null when nothing usable was stored at all.
         */
        fun fromStored(raw: String?): LibraryPrefs? {
            val obj = raw?.let { runCatching { PlainJson.parseToJsonElement(it) }.getOrNull() } as? JsonObject ?: return null
            fun str(k: String) = (obj[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val field = str("field")?.takeIf { it.isNotEmpty() } ?: "name"
            val dir = if (str("dir") == "desc") SortDirection.Descending else SortDirection.Ascending
            val favorite = (obj["favorite"] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull == true
            // "|" never appears in a real genre and once separated a stored form.
            val genre = str("genre")?.takeIf { it.isNotEmpty() && '|' !in it }
            // A JSON number, not a numeric string, as the desktop checks it.
            val decade = (obj["decade"] as? JsonPrimitive)?.takeIf { !it.isString && it.booleanOrNull == null }
                ?.doubleOrNull?.takeIf { it.isFinite() }?.toInt()
            val played = when (str("played")) {
                "played" -> BrowseFilter.Played.Played
                "unplayed" -> BrowseFilter.Played.Unplayed
                else -> BrowseFilter.Played.Any
            }
            return LibraryPrefs(field, dir, BrowseFilter(favorite, genre, decade, played))
        }

        const val ALBUMS_KEY = "cascade.albumsPrefs"
        const val ARTISTS_KEY = "cascade.artistsPrefs"
        const val PLAYLISTS_KEY = "cascade.playlistsPrefs"
        /** Songs keeps the desktop's own two keys, plus a filter of the Apple app's. */
        const val SONGS_SORT_FIELD_KEY = "cascade.songsSortField"
        const val SONGS_SORT_DIR_KEY = "cascade.songsSortDir"
        const val SONGS_FILTER_KEY = "cascade.songs.filter"
    }
}
