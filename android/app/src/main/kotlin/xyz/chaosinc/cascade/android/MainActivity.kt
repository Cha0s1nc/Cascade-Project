package xyz.chaosinc.cascade.android

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import xyz.chaosinc.cascade.android.playback.PlaybackService
import xyz.chaosinc.cascade.android.ui.CascadeRoot
import xyz.chaosinc.cascade.android.ui.CascadeTheme

class MainActivity : ComponentActivity() {
    private var controller: ListenableFuture<MediaController>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent { CascadeTheme { CascadeRoot() } }
    }

    /**
     * Connecting a controller is what starts the playback service and its
     * session, so the notification, lock screen and headset buttons are live
     * before the first play. The screens drive the engine directly; this
     * connection only keeps the service bound while the app is open.
     */
    override fun onStart() {
        super.onStart()
        controller = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlaybackService::class.java))).buildAsync()
    }

    override fun onStop() {
        controller?.let(MediaController::releaseFuture)
        controller = null
        super.onStop()
    }
}
