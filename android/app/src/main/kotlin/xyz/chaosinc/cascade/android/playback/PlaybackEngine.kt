package xyz.chaosinc.cascade.android.playback

import android.content.Context
import android.media.MediaCodecList
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import xyz.chaosinc.cascade.android.AppState
import xyz.chaosinc.cascade.core.DeviceProfile
import xyz.chaosinc.cascade.core.JellyfinClient
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.LAST_QUEUE_KEY
import xyz.chaosinc.cascade.core.PROGRESS_INTERVAL_MS
import xyz.chaosinc.cascade.core.PlaybackReporter
import xyz.chaosinc.cascade.core.PlaybackState
import xyz.chaosinc.cascade.core.QueueOrder
import xyz.chaosinc.cascade.core.RepeatMode
import xyz.chaosinc.cascade.core.ResolvedStream
import xyz.chaosinc.cascade.core.StreamingQuality
import xyz.chaosinc.cascade.core.appending
import xyz.chaosinc.cascade.core.instantMix
import xyz.chaosinc.cascade.core.moving
import xyz.chaosinc.cascade.core.msFromTicks
import xyz.chaosinc.cascade.core.parseSavedQueue
import xyz.chaosinc.cascade.core.playingNext
import xyz.chaosinc.cascade.core.removing
import xyz.chaosinc.cascade.core.resolveStream
import xyz.chaosinc.cascade.core.restoreQueue
import xyz.chaosinc.cascade.core.restoredItems
import xyz.chaosinc.cascade.core.savedQueueIds
import xyz.chaosinc.cascade.core.savedQueueOf
import xyz.chaosinc.cascade.core.setShuffle
import xyz.chaosinc.cascade.core.stopActiveEncoding
import xyz.chaosinc.cascade.core.ticksFromMs
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** What the screens draw the player from. The position is read from `player` directly, every frame where it matters. */
data class PlayerUiState(
    val queue: QueueOrder = QueueOrder(),
    val isPlaying: Boolean = false,
    val buffering: Boolean = false,
    val repeat: RepeatMode = RepeatMode.None,
    val durationMs: Long = 0,
    val error: String? = null,
) {
    val current: JfItem? get() = queue.current
    val shuffled: Boolean get() = queue.unshuffled != null
}

/** Artwork in the session's metadata goes by this scheme, never by a URL carrying the token. */
const val ART_SCHEME = "cascade-art"

/**
 * The one player, for the whole app: an ExoPlayer whose playlist IS the queue,
 * so gapless playback, the notification's transport, headset buttons and
 * audio focus are the player's own. The queue rules (Queue.kt, QueueActions.kt
 * in core) decide every change and are applied to the playlist here, in the
 * same order, so `state.queue` and the player never disagree.
 *
 * Shuffle reorders the playlist itself (the desktop's rule: the current track
 * moves to the front) rather than using ExoPlayer's shuffle mode, which would
 * put the current track somewhere random.
 *
 * Reporting follows PlaybackReporting.kt exactly: a start report when an entry
 * first plays, progress every 10 s and on every pause, resume and seek, and a
 * stopped report with the real position when it is left. They go out in order
 * through one queue, never awaited by playback.
 */
@OptIn(UnstableApi::class)
class PlaybackEngine(private val context: Context, private val app: AppState) {
    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val io = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var client: JellyfinClient? = null

    /** Each entry's latest resolve, for its reports. Keyed by item id. */
    private val resolutions = ConcurrentHashMap<String, CompletableDeferred<ResolvedStream>>()
    /** The same, once answered, for reports that must not wait. */
    private val resolved = ConcurrentHashMap<String, ResolvedStream>()

    /** What this device decodes, asked once: the profile claims nothing else. */
    val baseProfile: DeviceProfile by lazy { DeviceProfile.android(::hasDecoder) }

    private val resolver = StreamResolver { item ->
        val c = client ?: throw IOException("Signed out")
        val deferred = CompletableDeferred<ResolvedStream>()
        resolutions[item.mediaId]?.let { if (!it.isCompleted) it.cancel() }
        resolutions[item.mediaId] = deferred
        val stream = resolveStream(c, item.mediaId, currentProfile())
        resolved[item.mediaId] = stream
        deferred.complete(stream)
        stream
    }

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setMediaSourceFactory(ResolvingMediaSource.Factory(resolver, OkHttpDataSource.Factory(app.http), io))
        .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true)
        .setHandleAudioBecomingNoisy(true)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()

    private val _state = MutableStateFlow(PlayerUiState())
    val state: StateFlow<PlayerUiState> = _state.asStateFlow()

    private var queue: QueueOrder
        get() = _state.value.queue
        set(value) = _state.update { it.copy(queue = value) }

    /** The entry whose start report went out and whose stopped report has not. */
    private data class Started(val itemId: String, val serial: Long)
    private var started: Started? = null
    private var serial = 0L
    private var consecutiveErrors = 0
    private var lastSavedQueue: String? = null
    private var ticker: Job? = null

    private val reports = Channel<suspend () -> Unit>(Channel.UNLIMITED)

    init {
        io.launch { for (report in reports) runCatching { report() } }
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                serial++
                syncIndex()
                _state.update { it.copy(error = null) }
                if (player.isPlaying) reportStartIfNeeded()
                saveQueue()
            }

            override fun onPositionDiscontinuity(oldPosition: Player.PositionInfo, newPosition: Player.PositionInfo, reason: Int) {
                // An index that shifts because rows around it were removed
                // (shuffle, queue edits) is the same entry still playing.
                val leftEntry = reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION ||
                    (reason != Player.DISCONTINUITY_REASON_REMOVE && oldPosition.mediaItemIndex != newPosition.mediaItemIndex)
                if (leftEntry) {
                    val id = oldPosition.mediaItem?.mediaId
                    if (id != null && started?.itemId == id) reportStopped(id, oldPosition.positionMs)
                } else if (reason == Player.DISCONTINUITY_REASON_SEEK) {
                    reportProgress()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                _state.update { it.copy(isPlaying = isPlaying) }
                if (isPlaying) {
                    consecutiveErrors = 0
                    if (!reportStartIfNeeded()) reportProgress()
                    startTicker()
                } else {
                    // A pause is a state change: the server's view of it must not wait 10 s.
                    if (player.playbackState != Player.STATE_ENDED) reportProgress()
                    ticker?.cancel()
                    saveQueue()
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                _state.update { it.copy(buffering = playbackState == Player.STATE_BUFFERING, durationMs = duration()) }
                if (playbackState == Player.STATE_ENDED) {
                    started?.let { reportStopped(it.itemId, player.duration.coerceAtLeast(0)) }
                }
            }

            override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
                syncIndex()
                _state.update { it.copy(durationMs = duration()) }
            }

            override fun onPlayerError(error: PlaybackException) {
                _state.update { it.copy(error = error.message ?: "Playback failed") }
                started?.let { reportStopped(it.itemId, player.currentPosition) }
                // One bad file must not stop the whole queue, but a server that
                // is gone must not race through it either.
                consecutiveErrors++
                if (consecutiveErrors <= 3 && player.hasNextMediaItem()) {
                    player.seekToNextMediaItem()
                    player.prepare()
                    player.play()
                }
            }
        })
    }

    private fun duration(): Long = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }
        ?: msFromTicks(queue.current?.runTimeTicks ?: 0)

    private fun syncIndex() {
        val index = if (player.mediaItemCount == 0) -1 else player.currentMediaItemIndex
        if (index != queue.index) queue = queue.copy(index = index)
    }

    // MARK: - Session

    /** A new sign-in, or none. The queue is the caller's to clear (sign-out does). */
    fun attach(client: JellyfinClient?) {
        this.client = client
        resolutions.clear()
        resolved.clear()
    }

    /** The profile for this resolve: the decoders, capped by the quality for the network in use. */
    private fun currentProfile(): DeviceProfile {
        val metered = runCatching { context.getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered }.getOrDefault(false)
        val key = if (metered) StreamingQuality.CELLULAR_KEY else StreamingQuality.WIFI_KEY
        return baseProfile.capped(StreamingQuality.fromStored(app.settings.raw(key)))
    }

    private fun hasDecoder(mime: String): Boolean = runCatching {
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) }
        }
    }.getOrDefault(false)

    // MARK: - Starting playback

    fun mediaItemFor(item: JfItem): MediaItem = MediaItem.Builder()
        .setMediaId(item.id)
        .setUri("cascade://item/${item.id}")
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(item.name)
            .setArtist(item.artistLine)
            .setAlbumTitle(item.album)
            .setAlbumArtist(item.albumArtist)
            .setTrackNumber(item.indexNumber)
            .setDiscNumber(item.parentIndexNumber)
            .setDurationMs(item.runTimeTicks?.let(::msFromTicks))
            // The session hands this to other apps, so it names the art
            // rather than carrying a URL with the token in it; the session's
            // bitmap loader turns it into the real request.
            .setArtworkUri(Uri.parse("$ART_SCHEME://${item.artItemId}"))
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
            .setExtras(Bundle().apply { putString("albumId", item.albumId) })
            .build())
        .build()

    /** Replace the queue and play from `startIndex`. With `shuffle`, that track first and the rest shuffled. */
    fun play(items: List<JfItem>, startIndex: Int = 0, shuffle: Boolean = false, startPositionMs: Long = 0) {
        if (items.isEmpty()) return
        endCurrentEntry()
        var order = QueueOrder(items, startIndex.coerceIn(0, items.size - 1))
        if (shuffle) order = setShuffle(order, on = true)
        queue = order
        player.setMediaItems(order.items.map(::mediaItemFor), order.index, startPositionMs)
        player.prepare()
        player.play()
        saveQueue()
    }

    fun togglePlayPause() {
        if (player.isPlaying) player.pause() else resume()
    }

    fun resume() {
        if (player.mediaItemCount == 0) return
        // A restored queue is not loaded until the first play (as on the Mac).
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
        if (player.playbackState == Player.STATE_ENDED) player.seekTo(player.currentMediaItemIndex, 0)
        player.play()
    }

    fun pause() = player.pause()

    fun next() {
        if (player.hasNextMediaItem()) { player.seekToNextMediaItem(); ensurePrepared() }
    }

    /** Back to the start past 3 s in, otherwise the track before: the player's own rule, as on every platform. */
    fun previous() {
        player.seekToPrevious()
        ensurePrepared()
    }

    fun seekTo(positionMs: Long) = player.seekTo(positionMs.coerceAtLeast(0))

    fun jump(index: Int) {
        if (index !in 0 until player.mediaItemCount) return
        player.seekTo(index, 0)
        ensurePrepared()
        player.play()
    }

    private fun ensurePrepared() {
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
    }

    fun cycleRepeat() = setRepeat(_state.value.repeat.next)

    fun setRepeat(mode: RepeatMode) {
        player.repeatMode = when (mode) {
            RepeatMode.None -> Player.REPEAT_MODE_OFF
            RepeatMode.All -> Player.REPEAT_MODE_ALL
            RepeatMode.One -> Player.REPEAT_MODE_ONE
        }
        _state.update { it.copy(repeat = mode) }
    }

    /**
     * Shuffle on or off without interrupting the track playing: everything
     * around the current entry is replaced, the entry itself never is.
     */
    fun setShuffled(on: Boolean) {
        val before = queue
        if (before.current == null) return
        val after = setShuffle(before, on)
        if (after == before) return
        val cur = before.index
        val count = player.mediaItemCount
        if (cur + 1 < count) player.removeMediaItems(cur + 1, count)
        if (cur > 0) player.removeMediaItems(0, cur)
        player.addMediaItems(0, after.items.subList(0, after.index).map(::mediaItemFor))
        player.addMediaItems(after.items.subList(after.index + 1, after.items.size).map(::mediaItemFor))
        queue = after
        saveQueue()
    }

    // MARK: - Queue editing

    fun playNext(items: List<JfItem>) {
        if (items.isEmpty()) return
        if (player.mediaItemCount == 0) return play(items)
        val at = queue.index + 1
        queue = playingNext(queue, items)
        player.addMediaItems(at, items.map(::mediaItemFor))
        saveQueue()
    }

    fun addToQueue(items: List<JfItem>) {
        if (items.isEmpty()) return
        if (player.mediaItemCount == 0) return play(items)
        queue = appending(queue, items)
        player.addMediaItems(items.map(::mediaItemFor))
        saveQueue()
    }

    /** Move one row; `to` is the row's index after the move. */
    fun move(from: Int, to: Int) {
        if (from == to || from !in queue.items.indices || to !in queue.items.indices) return
        // The core rule takes an offset before the move, as drag lists report it.
        queue = moving(queue, listOf(from), if (to > from) to + 1 else to)
        player.moveMediaItem(from, to)
        saveQueue()
    }

    /** Remove a row. Never the playing one: the view does not offer it, and the rule refuses it. */
    fun remove(index: Int) {
        if (index == queue.index || index !in queue.items.indices) return
        queue = removing(queue, listOf(index))
        player.removeMediaItem(index)
        saveQueue()
    }

    /** Songs like this one, played now. */
    fun instantMix(seed: JfItem) {
        val c = client ?: return
        main.launch {
            val mix = runCatching { withContext(Dispatchers.IO) { c.instantMix(seed.id) } }.getOrNull().orEmpty()
            if (mix.isNotEmpty()) play(mix)
        }
    }

    /** Stop and empty the queue. `clearSaved` forgets the saved queue too (sign-out). */
    fun stopAndClear(clearSaved: Boolean = false) {
        endCurrentEntry()
        player.stop()
        player.clearMediaItems()
        queue = QueueOrder()
        _state.update { it.copy(isPlaying = false, error = null) }
        if (clearSaved) { app.settings.remove(LAST_QUEUE_KEY); lastSavedQueue = null }
    }

    /** Finish the playing entry's reporting before the queue is replaced. */
    private fun endCurrentEntry() {
        started?.let { reportStopped(it.itemId, player.currentPosition) }
    }

    // MARK: - Reporting

    private fun snapshot(itemId: String, positionMs: Long, stream: ResolvedStream?) = PlaybackState(
        itemId = itemId,
        positionTicks = ticksFromMs(positionMs),
        isPaused = !player.isPlaying,
        volumeLevel = (player.volume * 100).toInt(),
        playSessionId = stream?.playSessionId,
        mediaSourceId = stream?.mediaSourceId,
        playMethod = stream?.playMethod ?: xyz.chaosinc.cascade.core.PlayMethod.DirectPlay,
    )

    private suspend fun streamFor(itemId: String): ResolvedStream? =
        resolutions[itemId]?.let { withTimeoutOrNull(20_000) { runCatching { it.await() }.getOrNull() } }

    /** True when a start report went out now. */
    private fun reportStartIfNeeded(): Boolean {
        val item = player.currentMediaItem ?: return false
        if (started?.serial == serial && started?.itemId == item.mediaId) return false
        val id = item.mediaId
        started = Started(id, serial)
        val position = player.currentPosition
        val c = client ?: return true
        reports.trySend {
            // Waits for this entry's resolve, so the report carries its play session.
            val stream = streamFor(id)
            PlaybackReporter.start(c, withContext(Dispatchers.Main) { snapshot(id, position, stream) })
        }
        return true
    }

    private fun reportProgress() {
        val s = started ?: return
        val c = client ?: return
        val snap = snapshot(s.itemId, player.currentPosition, resolved[s.itemId])
        reports.trySend { PlaybackReporter.progress(c, snap) }
    }

    private fun reportStopped(itemId: String, positionMs: Long) {
        started = null
        val c = client ?: return
        val stream = resolved[itemId]
        val snap = snapshot(itemId, positionMs, stream)
        reports.trySend {
            PlaybackReporter.stopped(c, snap)
            // A transcode left behind keeps the server's encoder running.
            if (stream != null && !stream.direct) stopActiveEncoding(c, stream.playSessionId)
        }
    }

    private fun startTicker() {
        ticker?.cancel()
        ticker = main.launch {
            var elapsed = 0L
            while (isActive) {
                delay(5_000)
                elapsed += 5_000
                saveQueue()
                if (elapsed % PROGRESS_INTERVAL_MS == 0L) reportProgress()
            }
        }
    }

    // MARK: - Keeping the queue across launches

    /**
     * The desktop's `lastQueue`, as JSON text in `cascade.lastQueue`. Skipped
     * when unchanged, so the 5 s save costs nothing while a track just plays.
     */
    fun saveQueue() {
        val q = queue
        val saved = savedQueueOf(q.items, q.index, player.currentPosition / 1000.0, q.unshuffled.orEmpty()) ?: return
        val json = saved.json
        if (json == lastSavedQueue) return
        lastSavedQueue = json
        app.settings.putString(LAST_QUEUE_KEY, json)
    }

    /**
     * The last session's queue, put back paused where it was. Nothing loads
     * until the first play, so a launch costs the server one items request.
     */
    fun restoreSavedQueue() {
        if (player.mediaItemCount > 0) return
        val c = client ?: return
        val saved = parseSavedQueue(app.settings.string(LAST_QUEUE_KEY)) ?: return
        val ids = savedQueueIds(saved)
        if (ids.isEmpty()) return
        main.launch {
            val items = runCatching { withContext(Dispatchers.IO) { c.restoredItems(ids) } }.getOrNull() ?: return@launch
            val restored = restoreQueue(saved, items) ?: return@launch
            if (player.mediaItemCount > 0 || client !== c) return@launch
            val order = QueueOrder(restored.queue, restored.index, restored.unshuffled.takeIf { it.isNotEmpty() })
            queue = order
            player.setMediaItems(order.items.map(::mediaItemFor), order.index, (restored.positionSec * 1000).toLong())
            _state.update { it.copy(durationMs = duration()) }
        }
    }

    fun release() {
        endCurrentEntry()
        saveQueue()
        player.release()
    }
}
