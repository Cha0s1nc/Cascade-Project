package xyz.chaosinc.cascade.core

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64
import java.util.zip.Deflater

// Ported case for case from the desktop's test/lyrics.test.ts via CascadeKit,
// so the parsers cannot drift apart without one of them failing.
private const val SEC = Lyrics.TICKS_PER_SECOND_L

private fun json(s: String): JsonElement = PlainJson.parseToJsonElement(s)

class ParseLrcTest {
    @Test fun plainLinesCarryNoWordTiming() {
        assertEquals(listOf(LyricLine(12 * SEC + SEC / 2, "Hello world")), Lyrics.parseLRC("[00:12.50]Hello world"))
    }

    @Test fun wholeSecondTimestampsAreValid() {
        // Regression: fractional seconds used to be mandatory, and every [mm:ss] line was dropped.
        val out = Lyrics.parseLRC("[00:12]hello")
        assertEquals(listOf(12 * SEC), out.map { it.start })
        assertEquals(listOf("hello"), out.map { it.text })
    }

    @Test fun mixedWholeAndFractionalLines() {
        val out = Lyrics.parseLRC("[00:10]one\n[00:12.50]two\n[00:15]three")
        assertEquals(listOf("one", "two", "three"), out.map { it.text })
        assertEquals(listOf(10 * SEC, 12 * SEC + SEC / 2, 15 * SEC), out.map { it.start })
    }

    @Test fun wordTimestampsAllowWholeSeconds() {
        assertEquals(listOf(10 * SEC, 11 * SEC + SEC / 2), Lyrics.parseLRC("[00:10]<00:10>Hello <00:11.5>world")[0].words?.map { it.start })
    }

    @Test fun skipsMetadataAndBlankContent() {
        assertEquals(listOf("real"), Lyrics.parseLRC("[ti:Some Title]\n[ar:Artist]\n[00:01.00]\n[00:02.00]real").map { it.text })
    }

    @Test fun enhancedWordEndsChainToTheNextWord() {
        val out = Lyrics.parseLRC("[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:12.50]next")
        assertEquals(2, out.size)
        assertEquals("Hello world", out[0].text)
        val w = out[0].words!!
        assertEquals(10 * SEC, w[0].start)
        assertEquals(10 * SEC + SEC / 2, w[0].end)
        assertEquals(10 * SEC + SEC / 2, w[1].start)
        assertEquals(12 * SEC + SEC / 2, w[1].end)   // borrows the next line's start
    }

    @Test fun finalWordFallsBackTwoSeconds() {
        assertEquals(12 * SEC, Lyrics.parseLRC("[00:10.00]<00:10.00>only")[0].words!![0].end)
    }

    @Test fun barePunctuationJoinsThePreviousWord() {
        assertEquals(listOf("hey!"), Lyrics.parseLRC("[00:01.00]<00:01.00>hey<00:01.50>!")[0].words!!.map { it.text })
    }

    @Test fun perCharacterSourcesKeepTheirSpaces() {
        assertEquals("a b", Lyrics.parseLRC("[00:01.00]<00:01.00>a<00:01.10> <00:01.20>b")[0].text)
    }

    @Test fun timestampsRoundLikeTheDesktop() {
        assertEquals(105_300_000L, Lyrics.parseLRC("[00:10.53]x")[0].start)
    }

    @Test fun windowsLineEndings() {
        assertEquals(listOf("one", "two"), Lyrics.parseLRC("[00:01]one\r\n[00:02]two").map { it.text })
    }

    @Test fun activeLineIsTheLastOneStarted() {
        val lines = Lyrics.parseLRC("[00:01]a\n[00:05]b\n[00:09]c")
        assertNull(Lyrics.activeLineIndex(lines, 0))
        assertEquals(1, Lyrics.activeLineIndex(lines, 5 * SEC))
        assertEquals(2, Lyrics.activeLineIndex(lines, 60 * SEC))
    }
}

// Ported from the desktop's test/cascade-plugin.test.ts.
class CascadePluginTest {
    @Test fun statusMeaning() {
        assertEquals(CascadePluginProbe.Present, CascadePlugin.interpret(200))
        assertEquals(CascadePluginProbe.Absent, CascadePlugin.interpret(404))
        assertEquals(CascadePluginProbe.Unknown, CascadePlugin.interpret(401))
        assertEquals(CascadePluginProbe.Unknown, CascadePlugin.interpret(null))
    }

    @Test fun newRouteFirstThenLegacy() {
        assertEquals(CascadePluginProbe.Present to CascadePluginApi.Server, CascadePlugin.resolve(200, null))
        assertEquals(CascadePluginProbe.Unknown to CascadePluginApi.Legacy, CascadePlugin.resolve(404, 401))
        assertEquals(CascadePluginProbe.Absent to CascadePluginApi.Legacy, CascadePlugin.resolve(404, 404))
        // An unknown on the new route says nothing about the build: stay current.
        assertEquals(CascadePluginProbe.Unknown to CascadePluginApi.Server, CascadePlugin.resolve(500, null))
    }

    @Test fun lyricsRoutes() {
        assertEquals("/Audio/x/CascadeLyrics", CascadePlugin.lyricsPath(CascadePluginApi.Legacy, "x"))
        assertEquals("/CascadeServer/Lyrics/x", CascadePlugin.lyricsPath(CascadePluginApi.Server, "x"))
    }

    @Test fun wordProgressFillsAcrossTheWord() {
        val w = LyricWord(100, 200, "word ")
        assertEquals(0.0, Lyrics.wordProgress(w, 50), 0.0)
        assertEquals(0.5, Lyrics.wordProgress(w, 150), 0.0)
        assertEquals(1.0, Lyrics.wordProgress(w, 200), 0.0)
        // No end means "sung once started", never a division by zero.
        assertEquals(1.0, Lyrics.wordProgress(LyricWord(100, null, "x"), 101), 0.0)
    }

    @Test fun linesBeforeTheFirstAreAllUpcoming() {
        assertEquals(1, Lyrics.lineDistance(0, null as Int?))
        assertEquals(0, Lyrics.lineDistance(3, 3))
        assertEquals(-2, Lyrics.lineDistance(1, 3))
        assertEquals(2, Lyrics.lineDistance(5, 3))
    }

    @Test fun infoReadsThePluginsCamelCaseAndDefaults() {
        val old = PlainJson.decodeFromString(CascadePluginInfo.serializer(), """{"name":"x"}""")
        assertEquals(CascadePluginInfo(name = "x"), old)
        assertTrue(old.spotifyLinkServerWide)
        val new = PlainJson.decodeFromString(CascadePluginInfo.serializer(),
            """{"name":"Cascade Server","version":"2.1.0.0","capabilities":["syllable","spotify-link"],"spotifyLinkServerWide":false}""")
        assertTrue(new.spicy && new.spotifyLink && !new.spotifyLinkServerWide)
    }
}

// The desktop's currentLyricIndex and activeLyricRange cases.
class LyricGroupTest {
    private fun w(t: String, s: Double, e: Double) = LyricWord((s * SEC).toLong(), (e * SEC).toLong(), t)
    /** A one-word karaoke line ending at `e`; null means plain LRC with no end. */
    private fun line(s: Double, e: Double?, t: String = "x") = LyricLine((s * SEC).toLong(), t, e?.let { listOf(w(t, s, it)) })
    private fun at(s: Double) = (s * SEC).toLong()

    @Test fun aTightNextLineLightsEarlyButNotAnOverlapOrAWideGap() {
        val lines = listOf(line(0.0, 2.0), line(2.3, 4.0), line(5.0, 7.0), line(6.5, 8.0))
        val lead = SEC * 4 / 10
        assertEquals(1, Lyrics.tightNextIndex(lines, 0, at(1.95), lead))
        assertNull("not yet", Lyrics.tightNextIndex(lines, 0, at(1.8), lead))
        assertNull("gap too wide", Lyrics.tightNextIndex(lines, 1, at(4.8), lead))
        assertNull("overlap", Lyrics.tightNextIndex(lines, 2, at(6.4), lead))
        assertNull("off", Lyrics.tightNextIndex(lines, 0, at(1.95), 0))
        assertNull("no end", Lyrics.tightNextIndex(listOf(line(0.0, null), line(1.0, null)), 0, at(0.9), lead))
    }

    @Test fun waitsForBackgroundVocalsBeforeMovingOn() {
        val lead = line(10.0, 12.0, "lead").copy(background = listOf(w("ooh", 12.0, 15.0)))
        val lines = listOf(lead, line(20.0, 22.0, "next"))
        assertEquals(0, Lyrics.currentLineIndex(lines, 0, 13 * SEC))
        assertEquals(1, Lyrics.currentLineIndex(lines, 0, at(15.5)))
    }

    @Test fun backgroundRunningIntoTheNextLineLightsBoth() {
        val lead = line(10.0, 12.0, "lead").copy(background = listOf(w("ooh", 12.0, 21.0)))
        val lines = listOf(lead, line(13.0, 16.0, "next"))
        assertEquals(1, Lyrics.currentLineIndex(lines, 1, 14 * SEC))
        assertEquals(0..1, Lyrics.activeRange(lines, 1, 14 * SEC))
        assertEquals(0..1, Lyrics.activeRange(lines, 1, at(16.5)))
        assertEquals(1..1, Lyrics.activeRange(lines, 1, at(21.5)))
    }

    @Test fun aLineStartingInsideThePreviousKeepsBothLit() {
        val lines = listOf(line(0.0, 5.0, "before"), line(10.0, 14.0, "A"), line(12.0, 16.0, "B"), line(20.0, 22.0, "after"))
        assertEquals(1..2, Lyrics.activeRange(lines, 2, 13 * SEC))
        assertEquals(1..2, Lyrics.activeRange(lines, 2, 15 * SEC))
        assertEquals(2..2, Lyrics.activeRange(lines, 2, at(16.5)))
        assertEquals(1..1, Lyrics.activeRange(lines, 1, 11 * SEC))
    }

    @Test fun onlyLinesStillSungNotAChain() {
        assertEquals(1..2, Lyrics.activeRange(listOf(line(0.0, 6.0), line(4.0, 9.0), line(8.0, 12.0)), 2, 10 * SEC))
        assertEquals(0..2, Lyrics.activeRange(listOf(line(0.0, 12.0), line(4.0, 12.0), line(8.0, 12.0)), 2, 10 * SEC))
        assertEquals(1..1, Lyrics.activeRange(listOf(line(0.0, null), line(1.0, null)), 1, 2 * SEC))
    }

    @Test fun distanceIsZeroAcrossTheGroup() {
        assertEquals(0, Lyrics.lineDistance(1, 1..2))
        assertEquals(0, Lyrics.lineDistance(2, 1..2))
        assertEquals(-1, Lyrics.lineDistance(0, 1..2))
        assertEquals(2, Lyrics.lineDistance(4, 1..2))
        assertEquals(1, Lyrics.lineDistance(0, null as IntRange?))
    }
}

private const val SYLLABLE_BODY = """
{"Type": "Syllable", "id": "1QV6tiMFM6fSOKOGLMHYYg", "source": "spicy_lyrics",
 "UploadAttribution": {
   "Uploader": {"id": "1", "username": "spikerko", "url": "https://spicylyrics.org/uid/1"},
   "Maker": {"id": "2", "username": "gc", "url": "https://spicylyrics.org/uid/2"}},
 "Content": [{"Type": "Vocal",
   "Lead": {"StartTime": 7.357, "EndTime": 9.5, "Syllables": [
     {"Text": "Hel", "StartTime": 7.357, "EndTime": 7.6, "IsPartOfWord": true},
     {"Text": "lo", "StartTime": 7.6, "EndTime": 7.9},
     {"Text": "world", "StartTime": 8.2, "EndTime": 9.5}]},
   "Background": [{"Syllables": [{"Text": "oh", "StartTime": 8.5, "EndTime": 9.0}]}]}]}
"""

// Ported from the desktop's test/spicy-lyrics.test.ts.
class SpicyLyricsTest {
    @Test fun syllableSyncTicksJoinsAndKeepsGaps() {
        val line = SpicyLyrics.convert(json("{\"Body\": $SYLLABLE_BODY, \"Status\": 200}"))!!.lines.first()
        assertEquals(73_570_000L, line.start)
        assertEquals("Hello world", line.text)
        assertEquals(listOf("Hel", "lo ", "world"), line.words?.map { it.text })
        assertEquals(listOf("oh"), line.background?.map { it.text })
        assertEquals(listOf(85_000_000L), line.background?.map { it.start })
        // "lo" ends at 7.9 and "world" starts at 8.2: the pause is kept.
        assertEquals(79_000_000L, line.words!![1].end)
        assertEquals(82_000_000L, line.words!![2].start)
        assertFalse(line.opposite)
    }

    @Test fun acceptsTheBareBody() {
        assertEquals(1, SpicyLyrics.convert(json(SYLLABLE_BODY))?.lines?.size)
    }

    @Test fun untimedSyllableBorrowsPreviousEndAndTimelessGroupIsDropped() {
        val out = SpicyLyrics.convert(json("""
        {"Type": "Syllable", "source": "spicy_lyrics", "Content": [
          {"Lead": {"Syllables": [{"Text": "a", "StartTime": 1, "EndTime": 2}, {"Text": "b"}]}},
          {"Lead": {"Syllables": [{"Text": "lost"}]}}]}
        """))!!
        assertEquals(1, out.lines.size)
        assertEquals(2 * SEC, out.lines[0].words!![1].start)
    }

    @Test fun lineSyncKeepsTimedLinesOnly() {
        val out = SpicyLyrics.convert(json("""
        {"Type": "Line", "source": "apple_music", "Content": [
          {"Type": "Vocal", "Text": "first (echo)", "StartTime": 1.5, "EndTime": 3}, {"Text": "no time"}]}
        """))!!
        assertEquals(listOf(LyricLine(15_000_000, "first (echo)")), out.lines)
    }

    @Test fun nothingUsableIsNull() {
        for (junk in listOf("null", "\"x\"", "{}", "{\"Type\": \"Karaoke\"}", "{\"Type\": \"Syllable\", \"Content\": []}",
            "{\"Body\": {\"Type\": \"Static\", \"Lines\": []}}")) {
            assertNull(junk, SpicyLyrics.convert(json(junk)))
        }
    }

    @Test fun communityCreditNamesUploaderAndMaker() {
        assertEquals(SpicyCredit("Spicy Lyrics", SpicyContributor("spikerko", "https://spicylyrics.org/uid/1"),
            SpicyContributor("gc", "https://spicylyrics.org/uid/2")), SpicyLyrics.credit(json(SYLLABLE_BODY)))
    }

    @Test fun absentMakerIsNoMaker() {
        val c = SpicyLyrics.credit(json("""{"source": "spicy_lyrics", "UploadAttribution": {"Uploader": {"username": "spikerko"}}}"""))
        assertNull(c.maker)
        assertEquals("spikerko", c.uploader?.name)
    }

    @Test fun commercialSourceShowsOnlyTheProvider() {
        val apple = SYLLABLE_BODY.replace("\"spicy_lyrics\"", "\"apple_music\"")
        assertEquals(SpicyCredit("Apple Music via Spicy Lyrics"), SpicyLyrics.credit(json(apple)))
        assertEquals("Spicy Lyrics", SpicyLyrics.credit(json("{\"source\": \"something-new\"}")).provider)
    }

    @Test fun creditLinksAreHttpsOnly() {
        assertEquals("https://spicylyrics.org/uid/1", SpicyLyrics.safeCreditUrl(JsonPrimitive("https://spicylyrics.org/uid/1")))
        for (bad in listOf(JsonPrimitive("http://x.org"), JsonPrimitive("javascript:alert(1)"), JsonPrimitive("file:///etc/passwd"),
            JsonPrimitive("not a url"), JsonPrimitive(42), null)) {
            assertNull("$bad", SpicyLyrics.safeCreditUrl(bad))
        }
        val c = SpicyLyrics.credit(json("""{"source": "spicy_lyrics", "UploadAttribution": {"Uploader": {"username": "x", "url": "javascript:alert(1)"}}}"""))
        assertEquals(SpicyContributor("x", null), c.uploader)
    }

    @Test fun aSyncRunningPastTheFileIsAnotherVersion() {
        // The real case: Apple Music sync to 190.73 s, local file 186.6 s.
        assertFalse(SpicyLyrics.fitsTrack(json("{\"Body\": {\"EndTime\": 190.73}}"), 186.6))
        assertTrue(SpicyLyrics.fitsTrack(json("{\"EndTime\": 185}"), 186.6))
        assertTrue(SpicyLyrics.fitsTrack(json("{\"EndTime\": 187.5}"), 186.6))
        assertTrue(SpicyLyrics.fitsTrack(json("{\"Body\": {}}"), 186.6))
        assertTrue(SpicyLyrics.fitsTrack(json("{\"Body\": {\"EndTime\": 999}}"), 0.0))
        assertTrue(SpicyLyrics.fitsTrack(null, 186.6))
    }

    @Test fun aDuetKeepsWhichVoiceSingsEachLine() {
        fun vocal(text: String, t: Int, opposite: Boolean) = """
            {"Type": "Vocal", "OppositeAligned": $opposite, "Lead": {"StartTime": $t, "EndTime": ${t + 1},
             "Syllables": [{"Text": "$text", "StartTime": $t, "EndTime": ${t + 1}}]}}"""
        val out = SpicyLyrics.convert(json("{\"Type\": \"Syllable\", \"source\": \"spicy_lyrics\", \"Content\": [${vocal("Tame", 1, false)}, ${vocal("Jennie", 3, true)}]}"))!!
        assertEquals(listOf(false, true), out.lines.map { it.opposite })
        val lineSync = SpicyLyrics.convert(json("""
        {"Type": "Line", "source": "spicy_lyrics", "Content": [
          {"Text": "first voice", "StartTime": 1, "EndTime": 2, "OppositeAligned": false},
          {"Text": "second voice", "StartTime": 3, "EndTime": 4, "OppositeAligned": true}]}
        """))!!
        assertEquals(listOf(false, true), lineSync.lines.map { it.opposite })
    }

    @Test fun heldNotesAreASecondOrLongerAndShort() {
        assertTrue(Lyrics.isEmphasisWord(LyricWord(0, SEC, "now")))
        assertFalse(Lyrics.isEmphasisWord(LyricWord(0, SEC - 1, "now")))
        assertFalse(Lyrics.isEmphasisWord(LyricWord(0, null, "now")))
        assertFalse(Lyrics.isEmphasisWord(LyricWord(0, 2 * SEC, "...")))
        assertFalse(Lyrics.isEmphasisWord(LyricWord(0, 2 * SEC, "supercalifragilistic")))
    }

    @Test fun syllablesOfAWordStayTogether() {
        val words = listOf(LyricWord(0, 1, "Hel"), LyricWord(1, 2, "lo "), LyricWord(2, 3, "world"))
        assertEquals(listOf(listOf("Hel", "lo "), listOf("world")), Lyrics.wordUnits(words, true).map { u -> u.map { it.text } })
    }

    @Test fun aWordWithAHeldSyllableIsHeldWhole() {
        val words = listOf(LyricWord(0, 3 * SEC / 10, "y"), LyricWord(3 * SEC / 10, 2 * SEC, "eah "))
        val held = Lyrics.wordUnits(words, true)
        assertEquals(listOf(listOf("yeah ")), held.map { u -> u.map { it.text } })
        assertEquals(0L, held[0][0].start)
        assertEquals(2 * SEC, held[0][0].end)
        // Without emphasis (not SpicyLyrics) nothing is merged.
        assertEquals(listOf(2), Lyrics.wordUnits(words, false).map { it.size })
    }

    @Test fun noSpaceScriptsAndLongRunsAreNotHeldTogether() {
        val japanese = listOf(LyricWord(0, 1, "こん"), LyricWord(1, 2, "にちは"))
        assertEquals(listOf(1, 1), Lyrics.wordUnits(japanese, true).map { it.size })
        val long = (0 until 16).map { LyricWord(it.toLong(), it + 1L, "ab") }
        assertEquals(16, Lyrics.wordUnits(long, false).size)
    }

    @Test fun staticSyncIsUntimed() {
        val out = SpicyLyrics.convert(json("""{"Type": "Static", "source": "spotify", "Lines": [{"Text": "one"}, {"Text": "  "}, {"Text": "two"}]}"""))!!
        assertFalse(out.synced)
        assertEquals(listOf("one", "two"), out.lines.map { it.text })
    }
}

private const val MS = Lyrics.TICKS_PER_SECOND_L / 1000

class LyricSourcesTest {
    @Test fun krcWordOffsetsAreRelativeToTheLineStart() {
        val out = Lyrics.parseKrc("[1000,2000]<0,500,0>Hi<500,500,0> there")
        assertEquals(1, out.size)
        val line = out.first()
        assertEquals(1000 * MS, line.start)
        assertEquals("Hi there", line.text)
        // The space before "there" moves onto "Hi", the parseLRC convention.
        assertEquals(listOf("Hi ", "there"), line.words?.map { it.text })
        assertEquals(listOf(1000 * MS, 1500 * MS), line.words?.map { it.start })
        assertEquals(listOf(1500 * MS, 2000 * MS), line.words?.map { it.end })
    }

    @Test fun krcSkipsTagLines() {
        assertEquals(listOf("x"), Lyrics.parseKrc("[ti:Title]\n[offset:0]\n[100,200]<0,200,0>x").map { it.text })
    }

    @Test fun kugouContentDecrypts() {
        // Built the way Kugou builds it: zlib, XORed with the key, behind "krc1", in base64.
        val krc = "[ti:t]\n[1000,2000]<0,500,0>Hi<500,500,0> there\n"
        val deflater = Deflater()
        deflater.setInput(krc.toByteArray())
        deflater.finish()
        val buf = ByteArray(1024)
        val zlib = buf.copyOf(deflater.deflate(buf))
        val key = intArrayOf(64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105)
        for (i in zlib.indices) zlib[i] = (zlib[i].toInt() xor key[i % key.size]).toByte()
        val content = Base64.getEncoder().encodeToString("krc1".toByteArray() + zlib)
        assertEquals(krc, Kugou.decrypt(content))
        assertNull(Kugou.decrypt("not base64!"))
    }

    @Test fun creditLinesAreDropped() {
        val lines = listOf("Viva La Vida - Coldplay", "Written by: Chris Martin", "作词：某人", "Composed By : x",
            "I used to rule the world", "Lyrics are words").map { LyricLine(0, it) }
        assertEquals(listOf("I used to rule the world", "Lyrics are words"), Lyrics.droppingCredits(lines, "viva la vida").map { it.text })
    }

    @Test fun lrclibPrefersSyncedThenPlainAndFlagsInstrumentals() {
        val synced = LRCLIB.parse(json("""{"syncedLyrics":"[00:01.00]one","plainLyrics":"one"}""") as JsonObject)!!
        assertTrue(synced.synced)
        assertEquals(listOf("one"), synced.lines.map { it.text })
        val plain = LRCLIB.parse(json("""{"syncedLyrics":null,"plainLyrics":"one\n\n two \n"}""") as JsonObject)!!
        assertFalse(plain.synced)
        assertEquals(listOf("one", "two"), plain.lines.map { it.text })
        assertEquals(true, LRCLIB.parse(json("""{"instrumental":true}""") as JsonObject)?.instrumental)
        assertNull(LRCLIB.parse(json("""{"plainLyrics":""}""") as JsonObject))
    }

    @Test fun spotifyTrackIdsComeOutOfLinksUrisAndBareIds() {
        val id = "2VOomzT6VavJOGBeySqaMc"
        for (ok in listOf(id, " $id ", "spotify:track:$id", "https://open.spotify.com/track/$id",
            "https://open.spotify.com/track/$id?si=abc123", "open.spotify.com/intl-de/track/$id", "https://open.spotify.com/embed/track/$id")) {
            assertEquals(ok, id, Spotify.trackId(ok))
        }
        for (bad in listOf("", "nope", "https://open.spotify.com/album/$id", "https://open.spotify.com/playlist/$id",
            "https://evil.example/open.spotify.com/track/$id", "${id}x", "spotify:track:short")) {
            assertNull(bad, Spotify.trackId(bad))
        }
    }

    @Test fun storedChoicesAndModes() {
        assertEquals(LyricsSourceChoice.Kugou, LyricsSourceChoice.fromStored("Kugou"))
        assertEquals(LyricsSourceChoice.CascadeKaraoke, LyricsSourceChoice.fromStored("cascade-karaoke"))
        for (junk in listOf(null, "", "kugou", "Spicy", "stale-id")) assertEquals(LyricsSourceChoice.Auto, LyricsSourceChoice.fromStored(junk))
        assertEquals(listOf(LyricsSourceChoice.Auto, LyricsSourceChoice.Kugou, LyricsSourceChoice.LRCLIB, LyricsSourceChoice.Jellyfin),
            LyricsSourceChoice.choices(false))
        assertEquals(listOf(LyricsSourceChoice.Auto, LyricsSourceChoice.CascadeKaraoke, LyricsSourceChoice.CascadeSynced),
            LyricsSourceChoice.choices(true))
        assertEquals("Karaoke Only", LyricsSourceChoice.CascadeKaraoke.menuLabel)
        assertEquals("Synced", LyricsSourceChoice.CascadeSynced.label)
        assertEquals("Cascade", LyricsSourceChoice.CascadeSynced.statusKey)
        assertNull(LyricsSourceChoice.Auto.statusKey)
        assertEquals("karaoke", LyricsSourceChoice.CascadeKaraoke.pluginType)
        assertTrue(LyricsSourceChoice.autoHint(true).contains("karaoke"))
        assertTrue(LyricsSourceChoice.autoHint(false).contains("Kugou"))
    }
}

class ServerLyricsTest {
    private fun serve(routes: Map<String, Pair<Int, String>>, block: suspend (JellyfinClient, MockWebServer) -> Unit) = runBlocking {
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val (code, body) = routes[request.url.encodedPath] ?: (404 to "")
                return MockResponse.Builder().code(code).body(body).build()
            }
        }
        server.start()
        try { block(JellyfinClient(ServerConfig(server.url("/").toString(), "T", "U", deviceId = "D"), OkHttpClient(), testIdentity), server) }
        finally { server.close() }
    }

    @Test fun theProbeFallsBackToTheLegacyRoutes() = serve(mapOf("/CascadeLyrics/Info" to (200 to """{"name":"Cascade Lyrics"}"""))) { client, _ ->
        val state = client.probeCascadePlugin()
        assertEquals(CascadePluginProbe.Present, state.probe)
        assertEquals(CascadePluginApi.Legacy, state.api)
    }

    @Test fun noPluginIsAbsent() = serve(emptyMap()) { client, _ ->
        val state = client.probeCascadePlugin()
        assertEquals(CascadePluginProbe.Absent, state.probe)
        assertFalse(state.present)
    }

    @Test fun aSpicySyncComesWithItsCredit() = serve(mapOf("/CascadeServer/Lyrics/i" to (200 to """{"type":"syllable","spicy":$SYLLABLE_BODY}"""))) { client, server ->
        val r = client.serverLyrics("i", CascadePluginApi.Server, spicy = true, durationSeconds = 200.0)!!
        assertEquals("Spicy Lyrics", r.source)
        assertNotNull(r.credit)
        assertEquals("true", server.takeRequest().url.queryParameter("syllable"))
    }

    @Test fun theServerOnlyWaterfallAsksOnlyThePlugin() = serve(mapOf(
        "/CascadeServer/Lyrics/i" to (200 to """{"type":"synced","lrc":"[00:01]Song - x\n[00:02]real line"}"""),
    )) { client, server ->
        val plugin = CascadePluginState(CascadePluginProbe.Present, CascadePluginApi.Server, CascadePluginInfo())
        val out = LyricsWaterfall.fetch(LyricsWaterfall.Track("i", "Song", "x", "a", 100.0), client, plugin, serverOnly = true,
            spotifyId = null, userAgent = "test")
        assertEquals(listOf("real line"), out.result?.lines?.map { it.text })
        assertEquals(mapOf("Cascade" to LyricsFetchStatus.Ok), out.tried)
        assertEquals(1, server.requestCount)
    }

    @Test fun jellyfinsOwnLyricsAreUntimedWhenALineHasNoStart() = serve(mapOf(
        "/Audio/i/Lyrics" to (200 to """{"Lyrics":[{"Start":10000000,"Text":"one"},{"Text":"two"}]}"""),
    )) { client, _ ->
        val r = client.jellyfinLyrics("i")!!
        assertFalse(r.synced)
        assertEquals(listOf("one", "two"), r.lines.map { it.text })
    }
}

class LyricStyleTest {
    @Test fun storedValuesAreClampedAndUnknownKeysIgnored() {
        val v = LyricStyle.fromStored("""{"lyricSize":200,"pastOpacity":0.5,"nope":1,"lineGap":"wide"}""")
        assertEquals(60.0, v["lyricSize"]!!, 0.0)
        assertEquals(0.5, v["pastOpacity"]!!, 0.0)
        assertEquals(8.0, v["lineGap"]!!, 0.0)
        assertFalse(v.containsKey("nope"))
        assertEquals(LyricStyle.defaults, LyricStyle.fromStored("not json"))
        assertEquals(LyricStyle.defaults, LyricStyle.fromStored(null))
    }

    @Test fun onlyChangesAreStored() {
        assertEquals("{}", LyricStyle.stored(LyricStyle.defaults))
        val changed = LyricStyle.defaults + ("pastBlur" to 1.0)
        assertEquals("""{"pastBlur":1.0}""", LyricStyle.stored(changed))
        assertEquals(changed, LyricStyle.fromStored(LyricStyle.stored(changed)))
    }

    @Test fun theIphoneDefaultsHoldTheCurrentLineHigh() {
        assertEquals(0.12, LyricStyle.defaults["currentLinePosition"]!!, 0.0)
        assertEquals(30.0, LyricStyle.defaults["lyricSize"]!!, 0.0)
    }

    @Test fun looksByDistance() {
        val t = LyricTuning()
        assertEquals(LineLook(1.0, 0.0, 1.0), t.look(0, false))
        assertEquals(LineLook(0.3, 3.5, 0.75), t.look(-2, false))
        assertEquals(LineLook(0.15, 2.5, 1.0), t.look(1, false))
        assertEquals(0.0, t.look(9, false).opacity, 0.0)
        assertEquals(LineLook(0.8, 2.5, 1.0), t.look(4, true))
    }

    @Test fun aHeldNoteSwellsMoreTheLongerItIsAndSettlesAfter() {
        val t = LyricTuning()
        assertEquals(0.0, t.swell(-0.1, 1.0, 2.0), 0.0)
        // At the end of a full-length hold: all of it.
        assertEquals(1.0, t.swell(1.5, 1.5, 1.5), 1e-9)
        // A one-second hold peaks at the short-note strength.
        assertEquals(0.45, t.swell(1.0, 1.0, 1.0), 1e-9)
        // Released after the settle time.
        assertEquals(0.0, t.swell(1.5 + 0.4, 1.5, 1.5), 1e-9)
    }
}
