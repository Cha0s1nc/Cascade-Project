package xyz.chaosinc.cascade.android.playback

import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.graphics.Bitmap
import androidx.annotation.OptIn
import androidx.media3.common.util.BitmapLoader
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import xyz.chaosinc.cascade.android.CascadeApp
import xyz.chaosinc.cascade.android.MainActivity

/**
 * Keeps playback alive with the app in the background, and puts it on the
 * notification, the lock screen, Bluetooth and headset buttons, through
 * Media3's session. The player itself belongs to PlaybackEngine; this only
 * presents it, so the screens and the system always drive the same queue.
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        val state = CascadeApp.state
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaSession.Builder(this, state.engine.player)
            .setSessionActivity(open)
            .setBitmapLoader(CacheBitmapLoader(ArtBitmapLoader(
                DataSourceBitmapLoader.Builder(this).setDataSourceFactory(OkHttpDataSource.Factory(state.http)).build())))
            .build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    /** Swiped away while paused or empty: nothing is left to keep alive. Playing music keeps going. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val player = session?.player
        if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
            CascadeApp.state.engine.saveQueue()
            pauseAllPlayersAndStopSelf()
        }
    }

    override fun onDestroy() {
        CascadeApp.state.engine.saveQueue()
        // The player outlives the service: it belongs to the app, which may
        // bring the service back for the next play.
        session?.release()
        session = null
        super.onDestroy()
    }
}

/**
 * Turns the session's `cascade-art://<itemId>` artwork names into the real
 * image request. The URL carries the token as ApiKey, so it is built here, in
 * the app, rather than handed to every controller that reads the metadata.
 */
@OptIn(UnstableApi::class)
private class ArtBitmapLoader(private val inner: BitmapLoader) : BitmapLoader {
    override fun supportsMimeType(mimeType: String): Boolean = inner.supportsMimeType(mimeType)
    override fun decodeBitmap(data: ByteArray): ListenableFuture<Bitmap> = inner.decodeBitmap(data)
    override fun loadBitmap(uri: Uri): ListenableFuture<Bitmap> {
        if (uri.scheme != ART_SCHEME) return inner.loadBitmap(uri)
        val client = CascadeApp.state.session.value?.client
            ?: return Futures.immediateFailedFuture(IllegalStateException("Signed out"))
        return inner.loadBitmap(Uri.parse(client.imageUrl(uri.host ?: "", 512)))
    }
}
