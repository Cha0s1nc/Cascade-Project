package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun item(position: Long? = null, runtime: Long? = null, played: Boolean? = null) =
    JfItem(id = "x", runTimeTicks = runtime, userData = JfUserData(playbackPositionTicks = position, played = played))

class ResumeTicksTest {
    @Test fun noPositionStartsAtZero() {
        assertEquals(0L, resumeTicks(item()))
        assertEquals(0L, resumeTicks(null))
        assertEquals(0L, resumeTicks(item(position = 0)))
    }

    @Test fun honorsAStoredPosition() {
        assertEquals(300_000_000L, resumeTicks(item(300_000_000, 2_400_000_000)))
    }

    @Test fun playedItemsRestart() {
        assertEquals(0L, resumeTicks(item(300_000_000, 2_400_000_000, played = true)))
    }

    @Test fun positionPastTheCompleteRatioRestarts() {
        // 96% through: a leftover from finishing the track, not an intent.
        assertEquals(0L, resumeTicks(item(2_304_000_000, 2_400_000_000)))
        // 94%: still worth resuming.
        assertEquals(2_256_000_000L, resumeTicks(item(2_256_000_000, 2_400_000_000)))
    }
}

class StartTicksTest {
    @Test fun zeroOrLessLeavesTheUrlAlone() {
        val url = "https://s/videos/1/master.m3u8?a=b"
        assertEquals(url, withStartTicks(url, 0))
        assertEquals(url, withStartTicks(url, -5))
    }

    @Test fun appendsToAnExistingQuery() {
        val out = withStartTicks("https://s/videos/1/master.m3u8?a=b", 1234)
        assertTrue(out.contains("a=b"))
        assertTrue(out.contains("StartTimeTicks=1234"))
    }

    @Test fun replacesRatherThanDuplicating() {
        // Scrubbing twice must not leave two offsets, which the server
        // resolves by taking one of them and not necessarily the last.
        val once = withStartTicks("https://s/x?StartTimeTicks=1", 999)
        assertEquals(2, once.split("StartTimeTicks").size)
        assertTrue(once.contains("StartTimeTicks=999"))
    }
}

class AndroidProfileTest {
    private val everything = DeviceProfile.android { true }

    @Test fun claimsOnlyWhatTheDeviceDecodes() {
        // ALAC has no decoder on older Android: unclaimed, it transcodes
        // rather than direct playing into silence.
        val noAlac = DeviceProfile.android { it != "audio/alac" }
        assertFalse(noAlac.directPlayAudioCodecs.contains("alac"))
        assertTrue(noAlac.directPlayAudioCodecs.contains("flac"))
        assertTrue(everything.directPlayAudioCodecs.containsAll(listOf("flac", "alac", "aac", "mp3", "opus", "vorbis")))
    }

    @Test fun aContainerWithNothingDecodableIsLeftOut() {
        val none = DeviceProfile.android { false }
        // Only WAV, which ExoPlayer reads as PCM itself.
        assertEquals(listOf("wav"), none.directPlayProfiles.map { it.container })
        assertTrue(none.directPlayProfiles.none { it.audioCodec == "" })
    }

    @Test fun wavEntryHasNoAudioCodec() {
        // No AudioCodec means any codec in this container, which beats guessing
        // which pcm_* spelling this server reports.
        assertNull(everything.directPlayProfiles.first { it.container == "wav" }.audioCodec)
    }

    @Test fun transcodesToHlsAac() {
        val t = everything.transcodingProfiles.single()
        assertEquals("hls", t.streamProtocol)
        assertEquals("aac", t.audioCodec)
        assertEquals("ts", t.container)
    }

    @Test fun encodesTheWireNames() {
        val json = Json.parseToJsonElement(CascadeJson.encodeToString(DeviceProfile.serializer(), everything)).jsonObject
        val t = json["TranscodingProfiles"].toString()
        assertTrue(t.contains("\"Protocol\":\"hls\""))
        assertTrue(json["DirectPlayProfiles"].toString().contains("\"Type\":\"Audio\""))
        assertEquals(20_000_000L, everything.maxStreamingBitrate)
    }
}

class StreamingQualityTest {
    @Test fun storedValuesAreValidated() {
        assertEquals(StreamingQuality.Kbps128, StreamingQuality.fromStored(128_000))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromStored(0))
        // Nothing, a bitrate that is not a step, and the wrong type all fall
        // back to Original rather than reaching the server.
        assertEquals(StreamingQuality.Original, StreamingQuality.fromStored(null))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromStored(123))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromStored(-1))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromStored("320000"))
    }

    @Test fun theDesktopsStoredBitrateMapsOntoTheSteps() {
        assertEquals(StreamingQuality.Original, StreamingQuality.fromElectronBitrate(140_000_000))
        assertEquals(StreamingQuality.Kbps320, StreamingQuality.fromElectronBitrate(320_000))
        assertEquals(StreamingQuality.Kbps192, StreamingQuality.fromElectronBitrate("192000"))
        assertEquals(StreamingQuality.Kbps96, StreamingQuality.fromElectronBitrate(96_000))
        // Between steps: the one below, so a cap is never loosened.
        assertEquals(StreamingQuality.Kbps192, StreamingQuality.fromElectronBitrate(200_000))
        assertEquals(StreamingQuality.Kbps96, StreamingQuality.fromElectronBitrate(50_000))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromElectronBitrate(null))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromElectronBitrate(0))
        assertEquals(StreamingQuality.Original, StreamingQuality.fromElectronBitrate("fast"))
    }

    @Test fun capsTheProfile() {
        val p = DeviceProfile.android { true }
        assertEquals(p.maxStreamingBitrate, p.capped(StreamingQuality.Original).maxStreamingBitrate)
        assertEquals(192_000L, p.capped(StreamingQuality.Kbps192).maxStreamingBitrate)
    }

    @Test fun labels() {
        assertEquals("Original", StreamingQuality.Original.label)
        assertEquals("256 kbps", StreamingQuality.Kbps256.label)
    }
}

class ReportTest {
    @Test fun clampsVolumeToJellyfinScale() {
        assertEquals(100, PlaybackReport.of(PlaybackState("a", 10, volumeLevel = 250)).volumeLevel)
        assertEquals(0, PlaybackReport.of(PlaybackState("a", 10, volumeLevel = -5)).volumeLevel)
    }

    @Test fun neverReportsANegativePosition() {
        assertEquals(0L, PlaybackReport.of(PlaybackState("a", -100)).positionTicks)
    }

    @Test fun carriesTheSessionIdsThatTieToTheServerSession() {
        val s = PlaybackState("a", 0, playSessionId = "sess", mediaSourceId = "src", playMethod = PlayMethod.Transcode)
        val json = CascadeJson.encodeToString(PlaybackReport.serializer(), PlaybackReport.of(s))
        assertTrue(json.contains("\"PlaySessionId\":\"sess\""))
        assertTrue(json.contains("\"MediaSourceId\":\"src\""))
        assertTrue(json.contains("\"PlayMethod\":\"Transcode\""))
        assertTrue(json.contains("\"QueueableMediaTypes\":[\"Audio\"]"))
    }
}

class StreamUrlTest {
    private val config = ServerConfig("https://s/", "TOK", "U", deviceId = "D")

    @Test fun carriesTheContainerExtension() {
        val url = directStreamUrl(config, "item", MediaSource(id = "src", container = "flac"), "sess")!!.toHttpUrl()
        // Without the extension some servers re-probe the file every request.
        assertEquals("/Audio/item/stream.flac", url.encodedPath)
        assertEquals("true", url.queryParameter("static"))
        assertEquals("src", url.queryParameter("mediaSourceId"))
        assertEquals("sess", url.queryParameter("PlaySessionId"))
        assertEquals("TOK", url.queryParameter("ApiKey"))
        assertNull(url.queryParameter("api_key"))
    }

    @Test fun takesTheFirstOfSeveralContainers() {
        assertEquals("/Audio/i/stream.m4a",
            directStreamUrl(config, "i", MediaSource(container = "m4a,mp4"), null)!!.toHttpUrl().encodedPath)
    }

    @Test fun tickConversionRoundTrips() {
        assertEquals(425_000_000L, ticksFromSeconds(42.5))
        assertEquals(42.5, secondsFromTicks(425_000_000), 0.0)
        assertEquals(0L, ticksFromSeconds(-1.0))
        assertEquals(1500L, msFromTicks(ticksFromMs(1500)))
    }

    @Test fun seeksLocally() {
        assertTrue(ResolvedStream("http://h/Audio/x/stream?static=true", null, null, true).seeksLocally)
        // The bug: an HLS transcode re-requested with StartTimeTicks, which HLS
        // ignores, so every seek on a capped quality landed back at 0.
        assertTrue(ResolvedStream("http://h/Audio/x/main.m3u8?AudioCodec=aac", null, null, false).seeksLocally)
        assertFalse(ResolvedStream("http://h/Audio/x/universal?Container=mp3", null, null, false).seeksLocally)
    }
}

class ResolveStreamTest {
    private fun withServer(block: suspend (MockWebServer, JellyfinClient) -> Unit) = runBlocking {
        val server = MockWebServer()
        server.start()
        val client = JellyfinClient(ServerConfig(server.url("/").toString(), "TOK", "U", deviceId = "D"), OkHttpClient(), testIdentity)
        try { block(server, client) } finally { server.close() }
    }

    @Test fun aDirectSourceBecomesAStaticStream() = withServer { server, client ->
        server.enqueue(MockResponse.Builder().body("""{"MediaSources":[{"Id":"src","Container":"flac","SupportsDirectPlay":true}],"PlaySessionId":"ps"}""").build())
        val s = resolveStream(client, "item", DeviceProfile.android { true })
        assertTrue(s.direct)
        assertEquals("ps", s.playSessionId)
        assertTrue(s.url.contains("/Audio/item/stream.flac"))
        val req = server.takeRequest()
        assertEquals("/Items/item/PlaybackInfo?UserId=U", req.target)
        val body = Json.parseToJsonElement(req.body!!.utf8()).jsonObject
        assertEquals("U", body["UserId"]!!.jsonPrimitive.content)
        assertTrue(body.containsKey("DeviceProfile"))
        assertFalse("no start offset unless asked", body.containsKey("StartTimeTicks"))
    }

    @Test fun anHlsTranscodeNeverCarriesTheOffset() = withServer { server, client ->
        server.enqueue(MockResponse.Builder().body("""{"MediaSources":[{"Id":"src","TranscodingUrl":"/Audio/item/main.m3u8?AudioCodec=aac"}],"PlaySessionId":"ps"}""").build())
        val s = resolveStream(client, "item", DeviceProfile.android { true }, startTicks = 50_000_000)
        assertFalse(s.direct)
        assertEquals(0L, s.startTicks)
        assertFalse(s.url.contains("StartTimeTicks"))
        assertTrue(s.url.endsWith("/Audio/item/main.m3u8?AudioCodec=aac"))
    }

    @Test fun aFailureFallsBackToUniversalWithTheSameCap() = withServer { server, client ->
        server.enqueue(MockResponse.Builder().code(500).build())
        val s = resolveStream(client, "item", DeviceProfile.android { true }.capped(StreamingQuality.Kbps128))
        assertTrue(s.url.contains("/Audio/item/universal"))
        assertTrue(s.url.contains("MaxStreamingBitrate=128000"))
        assertTrue(s.url.contains("ApiKey=TOK"))
        assertNull(s.playSessionId)
    }
}
