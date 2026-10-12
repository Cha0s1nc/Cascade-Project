package xyz.chaosinc.cascade.core

// What each browsing screen can be sorted by, and the server's name for it.
//
// Sorting is the server's job, not the view's. Songs and Albums arrive a page
// at a time, and sorting only the pages loaded so far shows the wrong first row
// until the last page lands. So each choice maps to a sortBy the server
// understands; sortedLikeServer only puts several libraries back together.
// Every key used here is one sortedLikeServer handles (see its tests).

/** Ties broken by name, the same tie-break sortSongs and the desktop use. */
val SongSortField.serverSortBy: String
    get() = when (this) {
        // Name, not SortName: a song's SortName starts with its track number
        // ("0012 - Love"), so a Title sort ran in track-number order.
        SongSortField.Name -> "Name"
        SongSortField.Artist -> "AlbumArtist,SortName"
        SongSortField.Album -> "Album,SortName"
        SongSortField.Added -> "DateCreated,SortName"
        SongSortField.Played -> "DatePlayed,SortName"
    }

// Picking a date or a year almost always means newest first, so choosing one
// flips the direction to match; the person can still flip it back.
val SongSortField.defaultDirection: SortDirection
    get() = if (this == SongSortField.Added || this == SongSortField.Played) SortDirection.Descending else SortDirection.Ascending

val SongSortField.label: String
    get() = when (this) {
        SongSortField.Name -> "Title"; SongSortField.Artist -> "Artist"; SongSortField.Album -> "Album"
        SongSortField.Added -> "Date Added"; SongSortField.Played -> "Recently Played"
    }

enum class AlbumSortField(val raw: String, val label: String) {
    Name("name", "Title"), Artist("artist", "Artist"), Year("year", "Year"), Added("added", "Date Added"), Played("played", "Recently Played");

    /**
     * Null for Played: Jellyfin keeps no play date on an album (checked on
     * 10.11.11), so that order comes from the tracks instead. See albumsByRecentPlay.
     */
    val serverSortBy: String?
        get() = when (this) {
            Name -> "SortName"; Artist -> "AlbumArtist,SortName"; Year -> "ProductionYear,SortName"
            Added -> "DateCreated,SortName"; Played -> null
        }

    val defaultDirection: SortDirection
        get() = if (this == Year || this == Added || this == Played) SortDirection.Descending else SortDirection.Ascending

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: Name }
}

enum class ArtistSortField(val raw: String, val label: String) {
    Name("name", "Name"), Added("added", "Date Added");

    val serverSortBy: String get() = if (this == Added) "DateCreated,SortName" else "SortName"
    val defaultDirection: SortDirection get() = if (this == Added) SortDirection.Descending else SortDirection.Ascending

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: Name }
}

enum class PlaylistSortField(val raw: String, val label: String) {
    Name("name", "Name"), Added("added", "Date Added");

    val serverSortBy: String get() = if (this == Added) "DateCreated,SortName" else "SortName"
    val defaultDirection: SortDirection get() = if (this == Added) SortDirection.Descending else SortDirection.Ascending

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: Name }
}

/** Album ids in the order albumsByRecentPlay ranks them (newest first), for fetching just those. */
fun recentlyPlayedAlbumIds(playedTracks: List<JfItem>): List<String> = playedTracks.mapNotNull { it.albumId }.distinct()

/**
 * Albums in the order their tracks were last played, most recent first. An
 * album appears once, where its most recently played track put it. Albums with
 * no played track are left out: never-played albums mixed in is just noise.
 */
fun albumsByRecentPlay(playedTracks: List<JfItem>, albums: List<JfItem>): List<JfItem> {
    val rank = recentlyPlayedAlbumIds(playedTracks).withIndex().associate { it.value to it.index }
    return albums.filter { it.id in rank }.sortedBy { rank.getValue(it.id) }
}

/**
 * What a browsing screen is narrowed to: the desktop's library filters
 * (src/core/library-browse.ts), favorites, genre, decade and played. The
 * screens page in 200 at a time, so filtering what has loaded would miss the
 * rest, and the server filters.
 */
data class BrowseFilter(
    val favoritesOnly: Boolean = false,
    /** A genre's name: the items routes filter by name (`genres`), and a name is the same in every library where an id is not. */
    val genre: String? = null,
    /** The decade's first year: 1990 means 1990 to 1999. */
    val decade: Int? = null,
    val played: Played = Played.Any,
) {
    enum class Played(val raw: String) { Any("any"), Played("played"), Unplayed("unplayed") }

    val isActive: Boolean get() = this != BrowseFilter()

    /** The query parameters, only the ones set: "false" would mean "only non-favorites" to the server, not "either". */
    val params: Map<String, String>
        get() = buildMap {
            if (favoritesOnly) put("isFavorite", "true")
            genre?.let { put("genres", it) }
            decade?.let { d -> put("years", (d until d + 10).joinToString(",")) }
            when (played) {
                Played.Any -> {}
                Played.Played -> put("isPlayed", "true")
                Played.Unplayed -> put("isPlayed", "false")
            }
        }

    /**
     * Stored as "favorites|genre|decade|played" (`cascade.songs.filter`, the
     * Apple app's form), so Songs keeps its filter between launches.
     */
    val rawValue: String
        get() = listOf(if (favoritesOnly) "1" else "0", genre ?: "", decade?.toString() ?: "", played.raw).joinToString("|")

    companion object {
        /** Anything that does not read back cleanly is null, which callers treat as no filter. */
        fun fromRaw(raw: String?): BrowseFilter? {
            val parts = raw?.split("|") ?: return null
            if (parts.size != 4) return null
            val played = Played.entries.firstOrNull { it.raw == parts[3] } ?: return null
            return BrowseFilter(parts[0] == "1", parts[1].ifEmpty { null }, parts[2].toIntOrNull(), played)
        }

        /** The decades those years fall in, newest first. */
        fun decades(years: List<Int>): List<Int> = years.filter { it > 0 }.map { it / 10 * 10 }.distinct().sortedDescending()
    }
}

/** These parameters with a filter's on top, where it sets them. */
fun Map<String, String?>.applying(filter: BrowseFilter): Map<String, String?> = this + filter.params

/**
 * `sortBy` with keys appended so no two different items tie. Jellyfin breaks a
 * tie differently with and without `limit` (checked on 10.11.11), so a list
 * paged in 200s and the same list fetched whole for Play disagreed on order.
 * Random is left alone; a key already listed is not repeated.
 */
fun withTiebreakers(sortBy: String): String {
    val keys = sortBy.split(",").filter { it.isNotEmpty() }
    if (keys.isEmpty() || "Random" in keys) return sortBy
    return (keys + listOf("SortName", "AlbumArtist", "Album").filter { it !in keys }).joinToString(",")
}
