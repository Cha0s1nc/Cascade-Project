package xyz.chaosinc.cascade.core

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable

// The queries every browsing screen shares, written once and verified once.
// Each was checked against a live server (Jellyfin 10.11.11) when CascadeKit
// was written, and is ported here unchanged: writing against a remembered
// route is a mistake this project has already made on the desktop.

/**
 * Fields worth asking for on a list of tracks. Jellyfin omits most of these
 * unless asked, and a missing DateCreated silently breaks "recently added"
 * sorting rather than erroring.
 */
private const val TRACK_FIELDS = "DateCreated,PrimaryImageAspectRatio"

private val JellyfinClient.baseParams: Map<String, String?>
    get() = mapOf("userId" to currentConfig.userId, "recursive" to "true")

/** The user's libraries. Music ones have collectionType "music". */
suspend fun JellyfinClient.views(): List<JfItem> =
    get<JfItemsResponse>("/UserViews", mapOf("userId" to currentConfig.userId)).items.orEmpty()

/** The music libraries this app browses: whatever the user picked, or every one if they have not picked. */
suspend fun JellyfinClient.musicLibraries(): List<JfItem> {
    val music = views().filter { it.collectionType == "music" }
    val chosen = currentConfig.libraryIds
    return if (chosen.isEmpty()) music else music.filter { it.id in chosen }
}

/**
 * One query per selected library, run in parallel, merged in library order,
 * with the same song, album or artist found in two libraries shown once (see
 * mergeLibraryCopies). Jellyfin has no "these parents" parameter, so scoping
 * to more than one library genuinely is more than one request.
 */
suspend fun JellyfinClient.itemsAcrossLibraries(params: Map<String, String?>, path: String = "/Items"): List<JfItem> {
    var libraries = currentConfig.libraryIds
    // Nothing picked means the whole server, and one unscoped query covers
    // that, but it cannot say which library an item came from, so an album in
    // two music libraries showed twice. With two or more, ask each one.
    if (libraries.isEmpty()) {
        val music = runCatching { views().filter { it.collectionType == "music" } }.getOrNull().orEmpty()
        if (music.size > 1) libraries = music.map { it.id }
    }
    val p = params.toMutableMap()
    val fields = listOfNotNull(params["fields"]).toMutableList()
    // What sortedLikeServer needs to put several libraries back in one order.
    val sortBy = params["sortBy"] ?: ""
    if (sortBy.startsWith("SortName")) fields += "SortName"
    if (sortBy.startsWith("DateCreated")) fields += "DateCreated"
    // What mergeLibraryCopies compares copies by, only worth the bigger
    // response when there is more than one library to choose between.
    if (libraries.size > 1) {
        val types = params["includeItemTypes"] ?: ""
        if ("Audio" in types) fields += "MediaSources"
        if ("MusicAlbum" in types) fields += "ChildCount"
    }
    if (fields.isNotEmpty()) p["fields"] = fields.joinToString(",")

    if (libraries.isEmpty()) return get<JfItemsResponse>(path, p).items.orEmpty()

    val pages = coroutineScope {
        libraries.mapIndexed { index, library ->
            async {
                // One failing library must not sink the whole screen.
                runCatching { get<JfItemsResponse>(path, p + ("parentId" to library)).items.orEmpty() }
                    .getOrDefault(emptyList()).map { it.copy(sourceLibrary = index) }
            }
        }.awaitAll()
    }
    val merged = mergeLibraryCopies(pages.flatten())
    return if (libraries.size > 1) sortedLikeServer(merged, params["sortBy"], params["sortOrder"]) else merged
}

/** `isFavorite` is left out rather than "false" when off: false would mean "only non-favorites". */
suspend fun JellyfinClient.albums(limit: Int = 500, startIndex: Int = 0, sortBy: String = "SortName",
                                  sortOrder: String = "Ascending", genreId: String? = null,
                                  filter: BrowseFilter = BrowseFilter()): List<JfItem> =
    itemsAcrossLibraries((baseParams + mapOf(
        "includeItemTypes" to "MusicAlbum",
        "sortBy" to withTiebreakers(sortBy),
        "sortOrder" to sortOrder,
        "genreIds" to genreId,
        "limit" to limit.toString(),
        "startIndex" to startIndex.toString(),
    )).applying(filter))

/**
 * Albums whose tracks were played most recently, newest first. Jellyfin keeps
 * no play date on an album itself, so this reads the played tracks and then
 * fetches their albums. Capped: the ids go in the URL.
 */
suspend fun JellyfinClient.recentlyPlayedAlbums(maxAlbums: Int = 200, filter: BrowseFilter = BrowseFilter()): List<JfItem> {
    val played = itemsAcrossLibraries(baseParams + mapOf(
        "includeItemTypes" to "Audio", "sortBy" to "DatePlayed", "sortOrder" to "Descending",
        "filters" to "IsPlayed", "limit" to "1000",
    ))
    val ids = recentlyPlayedAlbumIds(played).take(maxAlbums)
    if (ids.isEmpty()) return emptyList()
    val albums = itemsAcrossLibraries((baseParams + mapOf(
        "includeItemTypes" to "MusicAlbum", "ids" to ids.joinToString(","),
    )).applying(filter))
    return albumsByRecentPlay(played, albums)
}

/**
 * Album artists rather than every credited artist, which is the list a music
 * app means by "Artists". A separate endpoint, not an item type.
 */
suspend fun JellyfinClient.artists(limit: Int = 500, startIndex: Int = 0, sortBy: String = "SortName",
                                   sortOrder: String = "Ascending", filter: BrowseFilter = BrowseFilter()): List<JfItem> =
    itemsAcrossLibraries(mapOf(
        "userId" to currentConfig.userId,
        // SortName is the server's default here, stated so the libraries can
        // be put back in the same order after merging.
        "sortBy" to sortBy,
        "sortOrder" to sortOrder,
        "limit" to limit.toString(),
        "startIndex" to startIndex.toString(),
    ).applying(filter), "/Artists/AlbumArtists")

/** A null `limit` means every song, in one response. */
suspend fun JellyfinClient.songs(limit: Int? = 500, startIndex: Int = 0, sortBy: String = "SortName",
                                 sortOrder: String = "Ascending", genreId: String? = null,
                                 filter: BrowseFilter = BrowseFilter()): List<JfItem> =
    itemsAcrossLibraries((baseParams + mapOf(
        "includeItemTypes" to "Audio",
        "sortBy" to withTiebreakers(sortBy),
        "sortOrder" to sortOrder,
        "genreIds" to genreId,
        "fields" to TRACK_FIELDS,
        "limit" to limit?.toString(),
        "startIndex" to startIndex.toString(),
    )).applying(filter))

/**
 * A random selection of songs, for Shuffle All. One request, so the first
 * track starts without waiting for the whole library; capped, because a
 * queue past a thousand songs is days of music. Shuffled again after merging:
 * each library comes back in its own random order, one after the other.
 */
suspend fun JellyfinClient.randomSongs(limit: Int = 1000, genreId: String? = null, filter: BrowseFilter = BrowseFilter()): List<JfItem> =
    songs(limit, sortBy = "Random", genreId = genreId, filter = filter).shuffled().take(limit)

/** The music genres in the chosen libraries. Jellyfin gives a genre one id across libraries, so the merge dedupes them. */
suspend fun JellyfinClient.genres(): List<JfItem> =
    itemsAcrossLibraries(mapOf("userId" to currentConfig.userId, "sortBy" to "SortName"), "/MusicGenres")

@Serializable
private data class ItemFilters(val years: List<Int>? = null)

/** The years with items of this type in the chosen libraries, for the decade filter. */
suspend fun JellyfinClient.years(itemType: String): List<Int> {
    val libraries: List<String?> = currentConfig.libraryIds.ifEmpty { listOf(null) }
    val years = sortedSetOf<Int>()
    for (parent in libraries) {
        years += get<ItemFilters>("/Items/Filters", mapOf(
            "userId" to currentConfig.userId, "parentId" to parent, "includeItemTypes" to itemType, "recursive" to "true",
        )).years.orEmpty()
    }
    return years.toList()
}

/** A genre's songs in album order, for its Play button. */
suspend fun JellyfinClient.songsInGenre(genreId: String): List<JfItem> =
    songs(null, sortBy = "AlbumArtist,Album,ParentIndexNumber,IndexNumber", genreId = genreId)

/** A genre's albums. */
suspend fun JellyfinClient.albumsInGenre(genreId: String): List<JfItem> =
    albums(limit = 500, sortBy = "SortName", genreId = genreId)

/** An album's tracks in playing order. Disc first: a two-disc album on track number alone interleaves the discs. */
suspend fun JellyfinClient.tracksInAlbum(albumId: String): List<JfItem> =
    get<JfItemsResponse>("/Items", mapOf(
        "userId" to currentConfig.userId, "parentId" to albumId,
        "sortBy" to "ParentIndexNumber,IndexNumber,SortName", "fields" to TRACK_FIELDS,
    )).items.orEmpty()

/**
 * The user's playlists. Not scoped to the chosen music libraries: playlists
 * live in Jellyfin's own playlists collection, so the filter would hide them all.
 */
suspend fun JellyfinClient.playlists(sortBy: String = "SortName", sortOrder: String = "Ascending"): List<JfItem> =
    get<JfItemsResponse>("/Items", mapOf(
        "userId" to currentConfig.userId, "includeItemTypes" to "Playlist", "recursive" to "true",
        "sortBy" to sortBy, "sortOrder" to sortOrder, "fields" to "ChildCount",
    )).items.orEmpty()

/** A playlist's tracks in the playlist's own order (no sortBy: the order is the playlist). */
suspend fun JellyfinClient.tracksInPlaylist(playlistId: String): List<JfItem> =
    get<JfItemsResponse>("/Playlists/$playlistId/Items", mapOf("userId" to currentConfig.userId, "fields" to TRACK_FIELDS))
        .items.orEmpty()

/** An artist's albums, newest first. */
suspend fun JellyfinClient.albumsByArtist(artistId: String): List<JfItem> =
    itemsAcrossLibraries(baseParams + mapOf(
        "albumArtistIds" to artistId, "includeItemTypes" to "MusicAlbum",
        "sortBy" to "ProductionYear,SortName", "sortOrder" to "Descending",
    ))

/** Every track by an artist, for the artist page's play button and Top Songs. */
suspend fun JellyfinClient.tracksByArtist(artistId: String, limit: Int = 500): List<JfItem> =
    itemsAcrossLibraries(baseParams + mapOf(
        "artistIds" to artistId, "includeItemTypes" to "Audio",
        "sortBy" to "Album,ParentIndexNumber,IndexNumber", "fields" to TRACK_FIELDS, "limit" to limit.toString(),
    ))

/**
 * Artists Jellyfin rates similar, kept to the ones in the selected libraries:
 * /Artists/{id}/Similar has no library scope of its own, so it is intersected
 * with the album artists the Artists tab lists.
 */
suspend fun JellyfinClient.similarArtists(artistId: String, limit: Int = 12): List<JfItem> = coroutineScope {
    val similar = async { get<JfItemsResponse>("/Artists/$artistId/Similar", mapOf("userId" to currentConfig.userId, "limit" to "24")) }
    val inLibraries = async {
        itemsAcrossLibraries(mapOf("userId" to currentConfig.userId, "enableImages" to "false", "enableUserData" to "false"),
            "/Artists/AlbumArtists")
    }
    val ids = inLibraries.await().map { it.id }.toSet()
    similar.await().items.orEmpty().filter { it.id in ids }.take(limit)
}

/** What the search box found, by kind. */
data class SearchResults(
    val songs: List<JfItem> = emptyList(),
    val albums: List<JfItem> = emptyList(),
    val artists: List<JfItem> = emptyList(),
) {
    val isEmpty: Boolean get() = songs.isEmpty() && albums.isEmpty() && artists.isEmpty()
}

/**
 * The desktop's search: songs, albums and artists, each its own query with its
 * own cap (10, 8, 8), so one kind with many matches cannot crowd the others
 * out of a shared limit. A kind that fails comes back empty rather than
 * sinking the rest, as the desktop's allSettled does.
 */
suspend fun JellyfinClient.searchEverything(term: String): SearchResults {
    val trimmed = term.trim()
    if (trimmed.isEmpty()) return SearchResults()
    return coroutineScope {
        val songs = async { runCatching { itemsAcrossLibraries(baseParams + mapOf(
            "searchTerm" to trimmed, "includeItemTypes" to "Audio", "fields" to TRACK_FIELDS, "limit" to "10")) }.getOrNull() }
        val albums = async { runCatching { itemsAcrossLibraries(baseParams + mapOf(
            "searchTerm" to trimmed, "includeItemTypes" to "MusicAlbum", "limit" to "8")) }.getOrNull() }
        // /Artists, not /Items, as the desktop does: it finds track artists too.
        val artists = async { runCatching { itemsAcrossLibraries(mapOf(
            "userId" to currentConfig.userId, "searchTerm" to trimmed, "limit" to "8"), "/Artists") }.getOrNull() }
        // Each merged list is cut back to its cap: several libraries return a full limit each.
        SearchResults(songs.await().orEmpty().take(10), albums.await().orEmpty().take(8), artists.await().orEmpty().take(8))
    }
}

// Home.

suspend fun JellyfinClient.recentlyAdded(limit: Int = 24): List<JfItem> =
    itemsAcrossLibraries(baseParams + mapOf(
        "includeItemTypes" to "MusicAlbum", "sortBy" to "DateCreated", "sortOrder" to "Descending", "limit" to limit.toString(),
    ))

suspend fun JellyfinClient.recentlyPlayed(limit: Int = 24): List<JfItem> =
    itemsAcrossLibraries(baseParams + mapOf(
        "includeItemTypes" to "Audio", "sortBy" to "DatePlayed", "sortOrder" to "Descending",
        // Without this the list is padded with never-played tracks, whose
        // DatePlayed is empty and which therefore sort arbitrarily.
        "filters" to "IsPlayed", "fields" to TRACK_FIELDS, "limit" to limit.toString(),
    ))

suspend fun JellyfinClient.frequentlyPlayed(limit: Int = 20): List<JfItem> =
    itemsAcrossLibraries(baseParams + mapOf(
        "includeItemTypes" to "Audio", "sortBy" to "PlayCount", "sortOrder" to "Descending",
        "filters" to "IsPlayed", "fields" to TRACK_FIELDS, "limit" to limit.toString(),
    ))

// Writes. Both throw on a bad status: a refused write that looked like a
// successful one is the exact desktop bug this guards against.

/**
 * Mark an item played, or not. userId is a QUERY parameter; the older
 * /Users/{userId}/PlayedItems/{id} route does not exist in 10.11.
 */
suspend fun JellyfinClient.setPlayed(played: Boolean, itemId: String) {
    val params = mapOf("userId" to currentConfig.userId)
    if (played) postRaw("/UserPlayedItems/$itemId", params = params) else delete("/UserPlayedItems/$itemId", params)
}

suspend fun JellyfinClient.setFavorite(favorite: Boolean, itemId: String) {
    val params = mapOf("userId" to currentConfig.userId)
    if (favorite) postRaw("/UserFavoriteItems/$itemId", params = params) else delete("/UserFavoriteItems/$itemId", params)
}

object ArtistPage {
    /** How many songs the Top Songs shelf shows. */
    const val TOP_SONGS_MAX = 10

    /**
     * The artist's songs this user has played most, ties by name. Jellyfin's
     * only popularity figure is this user's own play count, so a song never
     * played is not a top song. The desktop's topSongsOf.
     */
    fun topSongs(songs: List<JfItem>, max: Int = TOP_SONGS_MAX): List<JfItem> =
        songs.filter { (it.userData?.playCount ?: 0) > 0 }
            .sortedWith(compareByDescending<JfItem> { it.userData?.playCount ?: 0 }
                .thenComparator { a, b -> naturalCompare(a.name ?: "", b.name ?: "") })
            .take(max)
}
