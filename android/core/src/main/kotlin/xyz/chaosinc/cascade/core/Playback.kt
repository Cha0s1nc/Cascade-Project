package xyz.chaosinc.cascade.core

import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlin.math.roundToLong

/** Ticks are Jellyfin's unit everywhere: 100 nanoseconds. */
const val TICKS_PER_SECOND = 10_000_000.0

fun ticksFromSeconds(seconds: Double): Long = if (seconds <= 0) 0 else (seconds * TICKS_PER_SECOND).roundToLong()

fun secondsFromTicks(ticks: Long): Double = ticks / TICKS_PER_SECOND

fun ticksFromMs(ms: Long): Long = if (ms <= 0) 0 else ms * 10_000

fun msFromTicks(ticks: Long): Long = ticks / 10_000

/**
 * Past this fraction of the runtime an item counts as finished rather than
 * in progress. Resuming ninety seconds before the outro is nobody's intent.
 */
const val RESUME_COMPLETE_RATIO = 0.95

/** Where playback should pick up, in ticks. 0 means from the beginning. */
fun resumeTicks(item: JfItem?): Long {
    val ticks = item?.userData?.playbackPositionTicks ?: return 0
    if (ticks <= 0) return 0
    // Explicitly played: the position is a leftover, not an intent to resume.
    if (item.userData.played == true) return 0
    val total = item.runTimeTicks
    if (total != null && total > 0 && ticks > total * RESUME_COMPLETE_RATIO) return 0
    return ticks
}

/**
 * Put a start offset on a transcoding URL.
 *
 * A progressive transcode is a body the server encodes as it sends, so the
 * player only knows the part that has arrived and cannot seek past it.
 * Jellyfin's answer is a new stream that begins at the offset. Seeking must
 * not go back through PlaybackInfo: the URL the first resolve handed over is
 * still valid, and renegotiating to change one number costs a round trip.
 */
fun withStartTicks(url: String, startTicks: Long): String {
    if (startTicks <= 0) return url
    val parsed = url.toHttpUrlOrNull() ?: return url
    return parsed.newBuilder().removeAllQueryParameters("StartTimeTicks")
        .addQueryParameter("StartTimeTicks", startTicks.toString()).build().toString()
}

/**
 * An HLS playlist, as opposed to a progressive stream. A playlist covers the
 * whole item (checked against 10.11.11: StartTimeTicks on master.m3u8 changes
 * nothing, all the segments are still listed from 0), so the player seeks
 * anywhere in it and a start offset must never be counted on its clock.
 */
fun isHlsUrl(url: String): Boolean = Regex("\\.m3u8(\\?|$)", RegexOption.IGNORE_CASE).containsMatchIn(url)

enum class PlayMethod(val wire: String) { DirectPlay("DirectPlay"), DirectStream("DirectStream"), Transcode("Transcode") }

data class ResolvedStream(
    val url: String,
    /** Needed so playback reporting ties to the right server-side session. */
    val playSessionId: String?,
    val mediaSourceId: String?,
    /** False when the server chose to transcode. */
    val direct: Boolean,
    /**
     * Where this stream begins, in ticks. Non-zero only for a progressive
     * transcode asked to start partway in, the one case where the player's
     * clock is measured from somewhere other than the start of the item.
     */
    val startTicks: Long = 0,
) {
    val playMethod: PlayMethod get() = if (direct) PlayMethod.DirectPlay else PlayMethod.Transcode
    val isHls: Boolean get() = isHlsUrl(url)
    /** The whole item is in the player (a file, or an HLS playlist), so a seek never needs a new stream. */
    val seeksLocally: Boolean get() = direct || isHls
}

// PlaybackInfo wire shapes.

@Serializable
internal data class MediaSource(
    val id: String? = null,
    val container: String? = null,
    val supportsDirectPlay: Boolean? = null,
    val supportsTranscoding: Boolean? = null,
    /** Server-relative when present; means "transcode, use this". */
    val transcodingUrl: String? = null,
)

@Serializable
internal data class PlaybackInfoResponse(val mediaSources: List<MediaSource>? = null, val playSessionId: String? = null)

@Serializable
internal data class PlaybackInfoRequest(
    val userId: String,
    val maxStreamingBitrate: Long,
    val deviceProfile: DeviceProfile,
    val autoOpenLiveStream: Boolean,
    val startTimeTicks: Long? = null,
)

/** The desktop default, kept only for the `/universal` fallback URL which predates profile negotiation. */
const val DEFAULT_MAX_BITRATE = 140_000_000L

/**
 * The pre-negotiation stream URL, kept as a fallback. If PlaybackInfo fails
 * (older server, network blip, unexpected shape) this still plays audio:
 * `/universal` makes the server guess, acceptable as a degraded path, not as
 * the default. The server transcodes down to what is listed when it must.
 */
fun universalStreamUrl(config: ServerConfig, itemId: String, maxBitrate: Long = DEFAULT_MAX_BITRATE): String =
    "${config.url}/Audio/$itemId/universal?UserId=${config.userId}&ApiKey=${config.token}" +
        "&Container=mp3,aac,flac,wav,ogg,opus,m4a" +
        "&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac" +
        "&MaxStreamingBitrate=$maxBitrate"

internal fun directStreamUrl(config: ServerConfig, itemId: String, source: MediaSource, playSessionId: String?): String? {
    // The container extension matters: without it some servers re-probe the
    // file on every request.
    val ext = source.container?.split(",")?.firstOrNull()?.trim()?.takeIf { it.isNotEmpty() }?.let { ".$it" } ?: ""
    val base = "${config.url}/Audio/$itemId/stream$ext".toHttpUrlOrNull() ?: return null
    return base.newBuilder().apply {
        addQueryParameter("static", "true")
        // ApiKey, never api_key: the player sends no Authorization header.
        addQueryParameter("ApiKey", config.token)
        source.id?.let { addQueryParameter("mediaSourceId", it) }
        playSessionId?.let { addQueryParameter("PlaySessionId", it) }
    }.build().toString()
}

/**
 * Ask the server how to play an item, given what this client can decode.
 *
 * Never throws: on any failure it falls back to `universalStreamUrl`, so
 * playback degrades rather than dying.
 */
suspend fun resolveStream(client: JellyfinClient, itemId: String, profile: DeviceProfile, startTicks: Long = 0): ResolvedStream {
    val config = client.currentConfig
    val maxBitrate = profile.maxStreamingBitrate ?: DEFAULT_MAX_BITRATE
    return try {
        val text = client.post(
            "/Items/$itemId/PlaybackInfo",
            PlaybackInfoRequest(config.userId, maxBitrate, profile, true, startTicks.takeIf { it > 0 }),
            PlaybackInfoRequest.serializer(),
            // Also as a query param: 10.11 reads UserId from either, and the
            // body alone is not enough on some proxied setups.
            mapOf("UserId" to config.userId),
        )
        val info = CascadeJson.decodeFromString(PlaybackInfoResponse.serializer(), text)
        val source = info.mediaSources?.firstOrNull() ?: throw JellyfinException(0, "PlaybackInfo returned no media source")
        val transcoding = source.transcodingUrl
        if (transcoding != null) {
            // HLS ignores the offset: it starts at 0 and the player seeks, as
            // with a file. Counting the offset on its clock put a resumed or
            // seeked capped-quality track at the wrong place on the iPhone.
            val offset = if (isHlsUrl(transcoding)) 0 else startTicks
            ResolvedStream(withStartTicks(config.url + transcoding, offset), info.playSessionId, source.id, false, offset)
        } else {
            val url = directStreamUrl(config, itemId, source, info.playSessionId)
                ?: throw JellyfinException(0, "Bad direct stream URL")
            // Direct play hands over the whole file, so the player seeks in it
            // on its own and the offset is never baked into the URL.
            ResolvedStream(url, info.playSessionId, source.id, true, 0)
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        // The same cap as the negotiated request, so the fallback does not
        // quietly ignore the quality setting.
        ResolvedStream(universalStreamUrl(config, itemId, maxBitrate), null, null, false, 0)
    }
}

/**
 * Tell the server to stop transcoding for a play session. Abandoning a
 * transcode is not free and the server does not always notice: with
 * throttling off it keeps encoding at full speed for nobody. Best effort.
 */
suspend fun stopActiveEncoding(client: JellyfinClient, playSessionId: String?) {
    if (playSessionId == null) return
    runCatching {
        client.delete("/Videos/ActiveEncodings",
            mapOf("deviceId" to client.currentConfig.deviceId, "playSessionId" to playSessionId))
    }
}
