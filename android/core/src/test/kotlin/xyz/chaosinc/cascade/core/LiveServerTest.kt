package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Against a real server, the only check of the shapes this app sends against
 * what a given Jellyfin version accepts. Skipped unless CASCADE_SERVER is set,
 * so `./gradlew test` stays offline:
 *
 *   CASCADE_SERVER=https://host CASCADE_USER=name CASCADE_PASS=pw ./gradlew :core:test --tests '*LiveServerTest*'
 *
 * Reads only, unless CASCADE_LIVE_WRITES=1 also sends playback reports. Never
 * point writes at a server whose history matters.
 */
class LiveServerTest {
    private val server = System.getenv("CASCADE_SERVER")
    private val http = OkHttpClient()
    private val identity = ClientIdentity(ClientIdentity.ANDROID_EDITION, "Live Test", "0.0.0-test")
    private val deviceId = "cascade-android-live-test"

    private fun signedIn(): JellyfinClient = runBlocking {
        val auth = authenticate(http, identity, server!!, System.getenv("CASCADE_USER") ?: "", System.getenv("CASCADE_PASS") ?: "", deviceId)
        JellyfinClient(ServerConfig(server, auth.accessToken, auth.user.id, deviceId = deviceId), http, identity)
    }

    @Test fun signInBrowseAndResolve() = runBlocking {
        assumeTrue("CASCADE_SERVER not set", server != null)
        val client = signedIn()
        val libraries = client.musicLibraries()
        println("music libraries: ${libraries.map { it.name }}")
        val albums = client.albums(limit = 20)
        val songs = client.songs(limit = 20, sortBy = SongSortField.Name.serverSortBy)
        println("albums ${albums.size}, songs ${songs.size}")
        assertTrue("a demo library has songs", songs.isNotEmpty())
        val album = albums.first()
        val tracks = client.tracksInAlbum(album.id)
        assertTrue(tracks.isNotEmpty())
        assertTrue(client.searchEverything(songs.first().name!!.take(4)).songs.isNotEmpty())
        client.recentlyAdded(5)
        client.genres()
        client.playlists()

        // The token in a URL must be ApiKey: Jellyfin 12 refuses api_key by default.
        val image = http.newCall(Request.Builder().url(client.imageUrl(album.id, 96)).build()).execute()
        println("image ${image.code} ${image.header("Content-Type")}")
        assertTrue(image.code == 200 || image.code == 404)
        image.close()

        val profile = DeviceProfile.android { true }
        val stream = resolveStream(client, tracks.first().id, profile)
        println("stream direct=${stream.direct} hls=${stream.isHls} session=${stream.playSessionId}")
        assertNotNull("PlaybackInfo answered, not the fallback", stream.playSessionId)
        val bytes = http.newCall(Request.Builder().url(stream.url).header("Range", "bytes=0-1023").build()).execute()
        println("stream ${bytes.code} ${bytes.header("Content-Type")}")
        assertTrue(bytes.code in 200..299)
        bytes.close()

        val capped = resolveStream(client, tracks.first().id, profile.capped(StreamingQuality.Kbps128))
        println("capped direct=${capped.direct} hls=${capped.isHls}")

        val plugin = client.probeCascadePlugin()
        println("plugin ${plugin.probe} ${plugin.api} ${plugin.info}")
        println("quick connect enabled: ${QuickConnect.isEnabled(http, server!!)}")
        println("disclaimer: ${ServerMessage.fetchLoginDisclaimer(http, server).take(80)}")
        val lyrics = runCatching { client.jellyfinLyrics(tracks.first().id) }
        println("jellyfin lyrics: ${lyrics.getOrNull()?.lines?.size} ${lyrics.exceptionOrNull()?.message}")

        if (System.getenv("CASCADE_LIVE_WRITES") == "1") {
            val state = PlaybackState(tracks.first().id, 0, playSessionId = stream.playSessionId, mediaSourceId = stream.mediaSourceId,
                playMethod = stream.playMethod)
            assertTrue("the start report is taken", PlaybackReporter.start(client, state))
            PlaybackReporter.progress(client, state.copy(positionTicks = 50_000_000, isPaused = true))
            PlaybackReporter.stopped(client, state.copy(positionTicks = 60_000_000))
        }
    }

    @Test fun aWrongPasswordIsARefusalWithAStatus() = runBlocking {
        assumeTrue("CASCADE_SERVER not set", server != null)
        val e = runCatching { authenticate(http, identity, server!!, "cascade-no-such-user", "nope", deviceId) }.exceptionOrNull()
        assertTrue(e is JellyfinException)
        assertFalse((e as JellyfinException).status == 0)
        assertEquals(true, e.status in 400..499)
    }
}
