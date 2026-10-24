package xyz.chaosinc.cascade.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

// Jellyfin shapes, hand-written to cover only the fields Cascade actually
// reads. Deliberately not generated from the server's OpenAPI schema: that
// produces thousands of lines describing a surface this app never touches.
// If you start using a new field, add it here.
//
// The wire is PascalCase; these are Kotlin-cased. See Json.kt for the one rule
// that bridges them. Ticks are Long everywhere: 2^31 ticks is only 214 seconds.

@Serializable
data class JfUserData(
    val playCount: Int? = null,
    val lastPlayedDate: String? = null,
    val isFavorite: Boolean? = null,
    /** Where the user stopped, in ticks. Jellyfin fills this from the PositionTicks we report. */
    val playbackPositionTicks: Long? = null,
    val played: Boolean? = null,
)

/** One track inside a media source. */
@Serializable
data class JfMediaStream(
    /** "Audio", "Video", "Subtitle". */
    val type: String? = null,
    val index: Int? = null,
    val codec: String? = null,
    val language: String? = null,
    val displayTitle: String? = null,
    val isDefault: Boolean? = null,
)

@Serializable
data class JfImageTags(val primary: String? = null)

@Serializable
data class JfMediaSourceRef(
    val id: String? = null,
    val container: String? = null,
    /** Bits per second. How mergeLibraryCopies picks between two copies of a song. */
    val bitrate: Long? = null,
)

/** A name with the id it refers to, as Jellyfin nests artists in an item. */
@Serializable
data class JfNameId(val id: String, val name: String? = null)

/**
 * A track, album, artist or playlist. Jellyfin returns one shape for all of
 * them with different fields populated, hence almost everything nullable.
 *
 * Equality is structural on purpose (unlike CascadeKit's id-only JfItem): a
 * refetched item with a new play count must redraw its row, and Compose skips
 * a row whose argument compares equal. Compare `id` where identity is meant.
 */
@Serializable
data class JfItem(
    val id: String,
    val name: String? = null,
    /** "Audio", "MusicAlbum", "MusicArtist", "Playlist". The only thing separating a song from a movie. */
    val type: String? = null,
    val mediaType: String? = null,
    val album: String? = null,
    val albumId: String? = null,
    val albumArtist: String? = null,
    val artists: List<String>? = null,
    /** Art tags. Presence means art exists; the value is not used in image URLs. */
    val albumPrimaryImageTag: String? = null,
    val imageTags: JfImageTags? = null,
    /** Duration in ticks (100-nanosecond units). */
    val runTimeTicks: Long? = null,
    val dateCreated: String? = null,
    val indexNumber: Int? = null,
    /** Disc number on a track. Nil on an album with no discs reported, which sorts first. */
    val parentIndexNumber: Int? = null,
    val productionYear: Int? = null,
    /** Only sent when asked for (Fields=Genres). */
    val genres: List<String>? = null,
    /** Jellyfin's loudness scan, in dB: on a single item, not in lists. */
    val normalizationGain: Double? = null,
    val childCount: Int? = null,
    /** An artist's biography or an album's notes. Only sent for a single item. */
    val overview: String? = null,
    /** Only on library views (/UserViews): "music", "movies", etc. */
    val collectionType: String? = null,
    val mediaStreams: List<JfMediaStream>? = null,
    val mediaSources: List<JfMediaSourceRef>? = null,
    val userData: JfUserData? = null,
    /** The name Jellyfin sorts by ("Killers, The"), with Fields=SortName. */
    val sortName: String? = null,
    /** Which entry of a playlist this is, on /Playlists/{id}/Items. */
    val playlistItemId: String? = null,
    /** Artists with their ids, which Go to Artist needs; `artists` is names only. */
    val artistItems: List<JfNameId>? = null,
    val albumArtists: List<JfNameId>? = null,
    /**
     * Which selected library this came from, by position. Set by
     * itemsAcrossLibraries, never sent by the server; mergeLibraryCopies only
     * merges copies from different libraries.
     */
    @Transient val sourceLibrary: Int? = null,
) {
    /** The artist line a row shows: the track's artists, else its album artist. */
    val artistLine: String
        get() = artists?.takeIf { it.isNotEmpty() }?.joinToString(", ") ?: albumArtist ?: ""

    val durationSeconds: Double get() = (runTimeTicks ?: 0L) / TICKS_PER_SECOND

    val isFavorite: Boolean get() = userData?.isFavorite == true

    /**
     * The item whose Primary image to show. A track shows its album's, as on
     * the iPhone: embedded art is usually per album, and one cached image then
     * serves every row of that album. No art is a 404 the image view handles.
     */
    val artItemId: String get() = if (type == "Audio") albumId ?: id else id
}

/** Standard envelope for Jellyfin list endpoints. */
@Serializable
data class JfItemsResponse(val items: List<JfItem>? = null, val totalRecordCount: Int? = null)

@Serializable
data class JfAuthUser(val id: String, val name: String? = null)

@Serializable
data class JfAuthResult(val accessToken: String, val user: JfAuthUser)

/**
 * Connection state. `libraryIds` narrows every query to the user's chosen
 * music libraries; empty means "the whole server".
 *
 * `deviceId` must be unique per install. A constant makes every Cascade look
 * like the same device to the server, so remote control cannot target one of
 * them and two instances collide in the session list.
 */
class ServerConfig(
    url: String,
    val token: String,
    val userId: String,
    val libraryIds: List<String> = emptyList(),
    val deviceId: String,
) {
    /**
     * A trailing slash turns every path into a double slash, which some
     * reverse proxies answer with a redirect that drops the auth header.
     */
    val url: String = url.trimEnd('/')

    fun copy(token: String = this.token, userId: String = this.userId,
             libraryIds: List<String> = this.libraryIds, deviceId: String = this.deviceId, url: String = this.url) =
        ServerConfig(url, token, userId, libraryIds, deviceId)

    override fun equals(other: Any?): Boolean = other is ServerConfig && other.url == url && other.token == token &&
        other.userId == userId && other.libraryIds == libraryIds && other.deviceId == deviceId

    override fun hashCode(): Int = listOf(url, token, userId, libraryIds, deviceId).hashCode()
}
