package xyz.chaosinc.cascade.core

import kotlinx.serialization.Serializable

// Playback reporting: telling Jellyfin what this client is doing.
//
// Three endpoints: start, progress, stopped. The desktop app once called only
// start and stopped, which froze the server's view at the moment a track began:
// position never advanced, pause never registered, volume was never reported.
// A controller (the web UI, a phone) renders its transport from this state, so
// without progress reports its scrubber sits still. The server's resume points
// and play history depend on these, so they follow CascadeKit's exactly.
//
// Progress must be sent periodically AND on every state change.

/** How often to check in while playing. Jellyfin's own clients use about 10 s. */
const val PROGRESS_INTERVAL_MS = 10_000L

/**
 * How long a report may take. With the server unreachable (a tailnet that is
 * down hangs rather than refusing) each report held the next for a minute, so
 * skipping built a backlog that stamped plays with the wrong time. Not much
 * shorter: a slow link that loses the reply to a report the server did take
 * would count it twice.
 */
const val REPORT_TIMEOUT_SECONDS = 15L

/** A snapshot of local playback, in Jellyfin's units. */
data class PlaybackState(
    val itemId: String,
    /** 100 ns units. */
    val positionTicks: Long,
    val isPaused: Boolean = false,
    val isMuted: Boolean = false,
    /** 0 to 100, Jellyfin's scale. */
    val volumeLevel: Int = 100,
    val playSessionId: String? = null,
    val mediaSourceId: String? = null,
    val playMethod: PlayMethod = PlayMethod.DirectPlay,
    val canSeek: Boolean = true,
    /** "Audio" or "Video": what the server's session shows as playing. */
    val mediaType: String = "Audio",
)

/**
 * The payload shared by start and progress. VolumeLevel and IsMuted are the
 * fields a controller binds its volume UI to; omitting them is why remote
 * volume once appeared to do nothing.
 */
@Serializable
data class PlaybackReport(
    val itemId: String,
    val positionTicks: Long,
    val isPaused: Boolean,
    val isMuted: Boolean,
    val volumeLevel: Int,
    val canSeek: Boolean,
    val playMethod: String,
    val mediaType: String,
    /** How a controller decides whether it may push a track at this session. */
    val queueableMediaTypes: List<String>,
    val playSessionId: String? = null,
    val mediaSourceId: String? = null,
    val eventName: String? = null,
) {
    companion object {
        fun of(s: PlaybackState, eventName: String? = null) = PlaybackReport(
            itemId = s.itemId,
            positionTicks = maxOf(0, s.positionTicks),
            isPaused = s.isPaused,
            isMuted = s.isMuted,
            volumeLevel = s.volumeLevel.coerceIn(0, 100),
            canSeek = s.canSeek,
            playMethod = s.playMethod.wire,
            mediaType = s.mediaType,
            queueableMediaTypes = listOf("Audio"),
            playSessionId = s.playSessionId,
            mediaSourceId = s.mediaSourceId,
            eventName = eventName,
        )
    }
}

@Serializable
internal data class StoppedReport(
    val itemId: String,
    val positionTicks: Long,
    val playSessionId: String? = null,
    val mediaSourceId: String? = null,
)

/**
 * Reporting is best effort: a dropped check-in must never interrupt playback,
 * and these fire on a timer where a thrown error would be noise. The next
 * check-in re-syncs.
 */
object PlaybackReporter {
    /** Debug only: nothing goes to the server, so testing on a real library leaves its history alone. */
    @Volatile var muted = false

    /** Whether the server took it: this is the report Jellyfin counts a play on. */
    suspend fun start(client: JellyfinClient, state: PlaybackState): Boolean {
        if (muted) return true
        return runCatching {
            client.post("/Sessions/Playing", PlaybackReport.of(state), PlaybackReport.serializer(), timeoutSeconds = REPORT_TIMEOUT_SECONDS)
        }.isSuccess
    }

    suspend fun progress(client: JellyfinClient, state: PlaybackState) {
        if (muted) return
        val event = if (state.isPaused) "Pause" else "TimeUpdate"
        runCatching {
            client.post("/Sessions/Playing/Progress", PlaybackReport.of(state, event), PlaybackReport.serializer(),
                timeoutSeconds = REPORT_TIMEOUT_SECONDS)
        }
    }

    /** Playback ended. Drives play history, so position matters. */
    suspend fun stopped(client: JellyfinClient, state: PlaybackState) {
        if (muted) return
        runCatching {
            client.post("/Sessions/Playing/Stopped",
                StoppedReport(state.itemId, maxOf(0, state.positionTicks), state.playSessionId, state.mediaSourceId),
                StoppedReport.serializer(), timeoutSeconds = REPORT_TIMEOUT_SECONDS)
        }
    }
}
