package xyz.chaosinc.cascade.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Which family of Jellyfin stream endpoints an item uses. */
@Serializable
enum class MediaKind { Audio, Video }

@Serializable
data class DirectPlayProfile(
    val type: MediaKind,
    /** Comma-separated container list, e.g. "mp3,flac". */
    val container: String,
    val audioCodec: String? = null,
    val videoCodec: String? = null,
)

@Serializable
data class TranscodingProfile(
    val type: MediaKind,
    val container: String,
    val audioCodec: String,
    /** Encodes as "Protocol"; the naming rule turns "protocol" into that. */
    @SerialName("protocol") val streamProtocol: String,
    val context: String? = null,
    val maxAudioChannels: String? = null,
    val videoCodec: String? = null,
)

@Serializable
data class SubtitleProfile(val format: String, val method: String)

/**
 * What this client tells the server it can decode.
 *
 * The server trusts every claim in here, so a wrong one does not produce an
 * error: it produces a stream the device cannot decode, which sounds like
 * silence. Do not write a profile for hardware you do not have in hand.
 */
@Serializable
data class DeviceProfile(
    val name: String? = null,
    val maxStreamingBitrate: Long? = null,
    val directPlayProfiles: List<DirectPlayProfile>,
    val transcodingProfiles: List<TranscodingProfile>,
    val subtitleProfiles: List<SubtitleProfile> = emptyList(),
) {
    /** The codecs this profile claims it can direct play, lowercased. */
    val directPlayAudioCodecs: List<String>
        get() = directPlayProfiles.filter { it.type == MediaKind.Audio }
            .mapNotNull { it.audioCodec }
            .flatMap { it.split(",") }
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }

    /**
     * This profile capped at `quality`. The cap goes in the profile as well
     * as the request, since the server reads both.
     */
    fun capped(quality: StreamingQuality): DeviceProfile {
        val bitrate = quality.bitrate ?: return this
        return copy(maxStreamingBitrate = minOf(bitrate, maxStreamingBitrate ?: bitrate))
    }

    companion object {
        /**
         * Phones are on Wi-Fi or cellular, where the desktop's 140 Mbps ceiling
         * means nothing; the same number the iPhone uses. Every music file sits
         * under it, so Original never transcodes music for rate.
         */
        const val ANDROID_MAX_BITRATE = 20_000_000L

        /**
         * Jellyfin's codec names and the MIME type Android's MediaCodec knows
         * each by. ExoPlayer demuxes every container below itself; whether a
         * codec decodes is up to the device's decoders, so each one is asked
         * rather than assumed (ALAC, for one, has no decoder on older Android).
         */
        val audioCodecMimes: Map<String, String> = linkedMapOf(
            "flac" to "audio/flac",
            "alac" to "audio/alac",
            "aac" to "audio/mp4a-latm",
            "mp3" to "audio/mpeg",
            "opus" to "audio/opus",
            "vorbis" to "audio/vorbis",
        )

        /**
         * The profile for Android playing through ExoPlayer. `decodes` answers
         * whether a MIME type has a decoder on this device (the app asks
         * MediaCodecList; tests pass a fake), the desktop's injected-probe
         * pattern (src/core/profiles/electron.ts).
         *
         * Containers are what ExoPlayer's own extractors read: MP4 (m4a, m4b),
         * MP3, ADTS AAC, FLAC, Ogg (Vorbis, Opus), Matroska (webm, mka) and
         * WAV. Each entry lists only the codecs this device decodes, and a
         * container whose codecs all failed the probe is left out entirely.
         */
        fun android(decodes: (String) -> Boolean): DeviceProfile {
            val ok = audioCodecMimes.filter { (_, mime) -> decodes(mime) }.keys
            fun codecs(vararg wanted: String) = wanted.filter { it in ok }.joinToString(",")
            val entries = listOf(
                "m4a,m4b,mp4" to codecs("aac", "alac", "flac", "mp3", "opus"),
                "mp3" to codecs("mp3"),
                "aac" to codecs("aac"),
                "flac" to codecs("flac"),
                "ogg,oga,opus" to codecs("opus", "vorbis", "flac"),
                "webm,mka" to codecs("opus", "vorbis"),
            ).filter { it.second.isNotEmpty() }
                .map { DirectPlayProfile(MediaKind.Audio, it.first, it.second) }
            return DeviceProfile(
                name = "Cascade Android",
                maxStreamingBitrate = ANDROID_MAX_BITRATE,
                directPlayProfiles = entries + listOf(
                    // WAV with no audioCodec: its codec is PCM under one of
                    // several tag spellings Jellyfin reports (pcm_s16le and
                    // friends), and guessing which is exactly the kind of guess
                    // that presents as silence. ExoPlayer reads PCM itself.
                    DirectPlayProfile(MediaKind.Audio, "wav"),
                ),
                // HLS with AAC: an HLS playlist covers the whole item, so a
                // transcode seeks in the player like a file does. AAC has a
                // decoder on every Android device ExoPlayer supports.
                transcodingProfiles = listOf(
                    TranscodingProfile(MediaKind.Audio, "ts", "aac", "hls", context = "Streaming", maxAudioChannels = "2"),
                ),
            )
        }
    }
}
