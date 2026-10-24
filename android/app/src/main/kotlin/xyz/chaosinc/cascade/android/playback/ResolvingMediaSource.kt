package xyz.chaosinc.cascade.android.playback

import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.drm.DrmSessionManagerProvider
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.CompositeMediaSource
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.Allocator
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import xyz.chaosinc.cascade.core.ResolvedStream
import java.io.IOException

/** Turns a queue entry into a stream URL: PlaybackInfo, with the quality cap in force right now. */
fun interface StreamResolver {
    suspend fun resolve(item: MediaItem): ResolvedStream
}

/**
 * A playlist entry whose stream URL is only known once the server has been
 * asked (POST /Items/{id}/PlaybackInfo). With lazy preparation (on in
 * PlaybackEngine) the player wraps each entry in a MaskingMediaSource that
 * only prepares this source once a period is created for it: the playing
 * entry, and the next one once the current has buffered to its end (with the
 * default load control, up to about 50 s before the end of a long track, at
 * once for a short one). So a 200-song queue resolves one or two entries,
 * each under the streaming quality in force at that moment, and the handover
 * stays gapless: the counterpart of the iPhone's syncPreload, done by the
 * player itself.
 *
 * Until the answer arrives the source publishes no timeline (the player's
 * masking source shows a placeholder for it). Then it builds the real child:
 * progressive for a direct file, HLS for a transcode, so a transcode seeks in
 * the player like a file does. The child item keeps this item's id and
 * metadata and only changes the URI, so what the player reports as playing is
 * still the queue entry.
 */
@OptIn(UnstableApi::class)
class ResolvingMediaSource(
    private val item: MediaItem,
    private val resolver: StreamResolver,
    private val dataSourceFactory: DataSource.Factory,
    private val scope: CoroutineScope,
    private val loadErrorPolicy: LoadErrorHandlingPolicy?,
) : CompositeMediaSource<Unit>() {
    private var child: MediaSource? = null
    private var job: Job? = null
    private var failure: IOException? = null
    private var released = true

    override fun getMediaItem(): MediaItem = item

    override fun prepareSourceInternal(mediaTransferListener: TransferListener?) {
        super.prepareSourceInternal(mediaTransferListener)
        released = false
        failure = null
        val handler: Handler = Util.createHandlerForCurrentLooper()
        job = scope.launch {
            val result = runCatching { resolver.resolve(item) }
            handler.post {
                if (released) return@post
                result.onSuccess { stream ->
                    val resolved = item.buildUpon()
                        .setUri(stream.url)
                        .setMimeType(if (stream.isHls) MimeTypes.APPLICATION_M3U8 else null)
                        .build()
                    val source = if (stream.isHls) {
                        HlsMediaSource.Factory(dataSourceFactory).apply { loadErrorPolicy?.let(::setLoadErrorHandlingPolicy) }
                            .createMediaSource(resolved)
                    } else {
                        ProgressiveMediaSource.Factory(dataSourceFactory).apply { loadErrorPolicy?.let(::setLoadErrorHandlingPolicy) }
                            .createMediaSource(resolved)
                    }
                    child = source
                    prepareChildSource(Unit, source)
                }.onFailure { failure = IOException("Could not resolve ${item.mediaId}", it) }
            }
        }
    }

    override fun maybeThrowSourceInfoRefreshError() {
        failure?.let { throw it }
        super.maybeThrowSourceInfoRefreshError()
    }

    override fun onChildSourceInfoRefreshed(childSourceId: Unit?, mediaSource: MediaSource, newTimeline: Timeline) {
        refreshSourceInfo(newTimeline)
    }

    override fun createPeriod(id: MediaSource.MediaPeriodId, allocator: Allocator, startPositionUs: Long): MediaPeriod =
        // The player only asks once a timeline is out, which only the child publishes.
        checkNotNull(child) { "createPeriod before the stream was resolved" }.createPeriod(id, allocator, startPositionUs)

    override fun releasePeriod(mediaPeriod: MediaPeriod) {
        child?.releasePeriod(mediaPeriod)
    }

    override fun releaseSourceInternal() {
        released = true
        job?.cancel()
        job = null
        child = null
        failure = null
        super.releaseSourceInternal()
    }

    /** What the player is given in place of its default factory. */
    class Factory(
        private val resolver: StreamResolver,
        private val dataSourceFactory: DataSource.Factory,
        private val scope: CoroutineScope,
    ) : MediaSource.Factory {
        private var loadErrorPolicy: LoadErrorHandlingPolicy? = null

        override fun setDrmSessionManagerProvider(drmSessionManagerProvider: DrmSessionManagerProvider): MediaSource.Factory = this

        override fun setLoadErrorHandlingPolicy(loadErrorHandlingPolicy: LoadErrorHandlingPolicy): MediaSource.Factory {
            loadErrorPolicy = loadErrorHandlingPolicy
            return this
        }

        override fun getSupportedTypes(): IntArray = intArrayOf(androidx.media3.common.C.CONTENT_TYPE_OTHER, androidx.media3.common.C.CONTENT_TYPE_HLS)

        override fun createMediaSource(mediaItem: MediaItem): MediaSource =
            ResolvingMediaSource(mediaItem, resolver, dataSourceFactory, scope, loadErrorPolicy)
    }
}
