package xyz.chaosinc.cascade.core

import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Base64
import java.util.zip.Inflater

// The desktop's lyric waterfall (renderer.js _lyricsWaterfall), forced-source
// picker included, through CascadeKit's LyricSources.swift: where a track's
// lyrics come from.
//
// - Server-only: the Cascade plugin alone, SpicyLyrics first when the server
//   has a key, then the plugin's own files.
// - Otherwise all at once, first usable answer in this order: SpicyLyrics
//   (through the plugin, spicyOnly so a miss costs nothing), Kugou (only when
//   it has word timings), LRCLIB (synced, then plain), Jellyfin's own lyrics.
//   An instrumental flag wins, as on the desktop.

/** Lyrics for a track and where they came from. */
data class LyricsResult(
    val lines: List<LyricLine>,
    /** Set for SpicyLyrics, whose terms want it on screen with the lyrics. */
    val credit: SpicyCredit? = null,
    /** False for untimed lyrics, shown as a still page. Their lines' starts mean nothing. */
    val synced: Boolean = true,
    val source: String,
    /** The track is known to have no vocals; `lines` is empty. */
    val instrumental: Boolean = false,
) {
    companion object {
        internal val instrumentalTrack = LyricsResult(emptyList(), source = "LRCLIB", instrumental = true)
    }
}

/** What the plugin's Info route says: what it can do, and whether Spotify links apply server-wide. */
@Serializable
data class CascadePluginInfo(
    val name: String? = null,
    val version: String? = null,
    val capabilities: Set<String> = emptySet(),
    /** A plugin from before the setting existed sends nothing, and there any user could link songs for everyone. */
    val spotifyLinkServerWide: Boolean = true,
) {
    /** A SpicyLyrics key is set on the server. */
    val spicy: Boolean get() = "syllable" in capabilities
    val spotifyLink: Boolean get() = "spotify-link" in capabilities
    fun has(capability: String) = capability in capabilities
}

/** The plugin as this session found it. */
data class CascadePluginState(val probe: CascadePluginProbe, val api: CascadePluginApi, val info: CascadePluginInfo) {
    /** Unknown counts as present: never hide a working feature over a network hiccup. */
    val present: Boolean get() = probe != CascadePluginProbe.Absent
}

/** Kugou's KRC: `[lineStartMs,lineDurMs]<offsetMs,durMs,0>text...`, word offsets relative to the line. The desktop's parseKrc. */
fun Lyrics.parseKrc(text: String): List<LyricLine> {
    val ms = TICKS_PER_SECOND_L / 1000
    val out = mutableListOf<LyricLine>()
    for (raw in lines(text)) {
        val line = raw.trim()
        // Tags ([ti:], [offset:]) fail the digits and are skipped.
        val m = Regex("\\[(\\d+),(\\d+)\\](.*)").matchEntire(line) ?: continue
        val lineStart = m.groupValues[1].toLongOrNull() ?: continue
        val words = mutableListOf<LyricWord>()
        for (w in Regex("<(\\d+),(\\d+),\\d+>([^<]*)").findAll(m.groupValues[3])) {
            val offset = w.groupValues[1].toLongOrNull() ?: continue
            val duration = w.groupValues[2].toLongOrNull() ?: continue
            var t = w.groupValues[3]
            if (t.isEmpty()) continue
            // KRC puts the space before a word (" there"); it moves to the end
            // of the word before, the convention parseLRC and the karaoke
            // layout use, so words group and wrap the same way.
            val lead = t.takeWhile { it.isWhitespace() }
            if (lead.isNotEmpty() && words.isNotEmpty()) {
                words[words.size - 1] = words.last().let { it.copy(text = it.text + lead) }
                t = t.drop(lead.length)
            }
            if (t.isEmpty()) continue
            words += LyricWord((lineStart + offset) * ms, (lineStart + offset + duration) * ms, t)
        }
        val full = words.joinToString("") { it.text }.trim()
        if (full.isNotEmpty()) out += LyricLine(lineStart * ms, full, words.ifEmpty { null })
    }
    return out
}

private val creditLine = Regex("^(?i:composed|written|produced|arranged|performed|lyrics|music|words|publisher|作词|作曲|编曲|编词|制作人)\\s*(?i:by)?\\s*[:：]")

/** Drops the credits some sources put in the lyrics: a "Title - " opening line, and "Written by:", 作词: and the like. */
fun Lyrics.droppingCredits(lines: List<LyricLine>, title: String): List<LyricLine> = lines.filter { line ->
    if (creditLine.containsMatchIn(line.text)) return@filter false
    if (title.isEmpty() || !line.text.lowercase().startsWith(title.lowercase())) return@filter true
    !Regex("^\\s*-\\s*").containsMatchIn(line.text.drop(title.length))
}

/** Plain text, one line each, for an untimed sheet. */
fun Lyrics.plainLines(text: String): List<LyricLine> =
    lines(text).map { it.trim() }.filter { it.isNotEmpty() }.map { LyricLine(0, it) }

/** Kugou's lyrics service: word-level KRC, no account needed. */
object Kugou {
    private val key = intArrayOf(64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105)

    /** A download's `content`: base64 of "krc1", then the rest XORed with a fixed key, which gives a zlib stream. */
    fun decrypt(content: String): String? = runCatching {
        val data = Base64.getDecoder().decode(content)
        if (data.size <= 10) return null
        val bytes = data.copyOfRange(4, data.size)
        for (i in bytes.indices) bytes[i] = (bytes[i].toInt() xor key[i % key.size]).toByte()
        val inflater = Inflater()
        inflater.setInput(bytes)
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (!inflater.finished()) {
            val n = inflater.inflate(buf)
            if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
            out.write(buf, 0, n)
        }
        inflater.end()
        out.toString(Charsets.UTF_8.name())
    }.getOrNull()

    /** The best match's lyrics as KRC text, or null. */
    suspend fun krc(http: OkHttpClient, title: String, artist: String, durationMs: Long): String? {
        val search = "https://lyrics.kugou.com/search".toHttpUrl().newBuilder()
            .addQueryParameter("ver", "1").addQueryParameter("man", "yes").addQueryParameter("client", "pc")
            .addQueryParameter("keyword", "$artist - $title").addQueryParameter("duration", durationMs.toString()).build()
        val found = PlainJson.parseToJsonElement(http.send(Request.Builder().url(search).build())).obj()
        val candidate = found?.get("candidates").arr().firstOrNull().obj() ?: return null
        val id = candidate["id"]?.let { it.str() ?: it.num()?.toLong()?.toString() } ?: return null
        val accessKey = candidate["accesskey"].str() ?: return null
        val download = "https://lyrics.kugou.com/download".toHttpUrl().newBuilder()
            .addQueryParameter("ver", "1").addQueryParameter("client", "pc").addQueryParameter("id", id)
            .addQueryParameter("accesskey", accessKey).addQueryParameter("fmt", "krc").addQueryParameter("charset", "utf8").build()
        val content = PlainJson.parseToJsonElement(http.send(Request.Builder().url(download).build())).obj()?.get("content").str()
            ?: return null
        return decrypt(content)
    }
}

/** LRCLIB, the open lyrics database: synced LRC, else plain text. */
object LRCLIB {
    suspend fun lyrics(http: OkHttpClient, title: String, artist: String, album: String, durationSeconds: Long,
                       userAgent: String): LyricsResult? {
        val url = "https://lrclib.net/api/get".toHttpUrl().newBuilder()
            .addQueryParameter("artist_name", artist).addQueryParameter("track_name", title)
            .addQueryParameter("album_name", album).addQueryParameter("duration", durationSeconds.toString()).build()
        // LRCLIB asks every client to say who it is.
        val text = runCatching { http.send(Request.Builder().url(url).header("User-Agent", userAgent).build()) }.getOrNull() ?: return null
        return parse(PlainJson.parseToJsonElement(text).obj() ?: return null)
    }

    fun parse(reply: JsonObject): LyricsResult? {
        if (reply["instrumental"].bool() == true) return LyricsResult.instrumentalTrack
        reply["syncedLyrics"].str()?.let { synced ->
            val lines = Lyrics.parseLRC(synced)
            if (lines.isNotEmpty()) return LyricsResult(lines, source = "LRCLIB")
        }
        reply["plainLyrics"].str()?.let { plain ->
            val lines = Lyrics.plainLines(plain)
            if (lines.isNotEmpty()) return LyricsResult(lines, synced = false, source = "LRCLIB (plain)")
        }
        return null
    }
}

/**
 * Which plugin build the server runs, asked once per session: the new Info
 * route, then the pre-rename one on a 404 (an old server may still run Cascade
 * Lyrics 1.0.0.0, which only answers the legacy routes).
 */
suspend fun JellyfinClient.probeCascadePlugin(): CascadePluginState {
    // The plugin answers in ASP.NET's camelCase, not Jellyfin's PascalCase, so
    // its replies are read with the plain rule (CascadeKit's decoder accepts
    // either first-letter case; this one is explicit instead).
    suspend fun status(path: String): Pair<Int?, CascadePluginInfo> = try {
        200 to PlainJson.decodeFromString(CascadePluginInfo.serializer(), getText(path))
    } catch (e: JellyfinException) {
        (if (e.status == 0) null else e.status) to CascadePluginInfo()
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        // A 200 with a body that is not Info: the route exists, so something answers it.
        200 to CascadePluginInfo()
    }
    var (server, info) = status("/CascadeServer/Info")
    var legacy: Int? = null
    if (server == 404) { val r = status("/CascadeLyrics/Info"); legacy = r.first; info = r.second }
    val (probe, api) = CascadePlugin.resolve(server, legacy)
    return CascadePluginState(probe, api, info)
}

/**
 * The plugin's lyrics for a track, parsed. Null when it has none: the lyrics
 * route answers a bare 404 for that, which is not an error here.
 *
 * With `spicy` (the plugin reports a SpicyLyrics key), asks for those first
 * (`syllable=true`); the plugin answers them only when it can match the track,
 * and otherwise falls through to its own files in the same reply. A
 * SpicyLyrics sync for another release of the song (fitsTrack), or that will
 * not convert, is set aside and the plugin's own files asked for instead.
 * `spicyOnly` stops there instead, for the waterfall, which has other sources.
 */
suspend fun JellyfinClient.serverLyrics(itemId: String, api: CascadePluginApi, spicy: Boolean, durationSeconds: Double,
                                        spotifyId: String? = null, spicyOnly: Boolean = false,
                                        wantType: String? = null): LyricsResult? {
    val path = CascadePlugin.lyricsPath(api, itemId)
    fun parsed(lrc: String?): LyricsResult? {
        val lines = Lyrics.parseLRC(lrc ?: "")
        return if (lines.isEmpty()) null else LyricsResult(lines, source = "Cascade")
    }
    return try {
        // A forced Karaoke or Synced choice means exactly the plugin's own
        // files of that type, never SpicyLyrics.
        if (wantType != null) {
            val reply = getJson(path).obj()
            if (reply?.get("Type").str() != wantType && reply?.get("type").str() != wantType) return null
            val found = parsed(reply?.get("Lrc").str() ?: reply?.get("lrc").str()) ?: return null
            return found.copy(source = if (wantType == "karaoke") "Karaoke" else "Synced")
        }
        if (spicy) {
            val reply = getJson(path, mapOf("syllable" to "true", "spicyOnly" to if (spicyOnly) "true" else null,
                "spotifyId" to spotifyId)).obj()
            if (reply?.get("type").str() == "syllable") {
                val sync = reply?.get("spicy")
                if (SpicyLyrics.fitsTrack(sync, durationSeconds)) {
                    SpicyLyrics.convert(sync)?.let { conv ->
                        return LyricsResult(conv.lines, conv.credit, conv.synced, conv.credit.provider)
                    }
                }
                if (spicyOnly) return null
            } else if (reply != null) {
                return if (spicyOnly) null else parsed(reply["lrc"].str() ?: reply["Lrc"].str())
            }
        }
        val reply = getJson(path).obj()
        parsed(reply?.get("Lrc").str() ?: reply?.get("lrc").str())
    } catch (e: JellyfinException) {
        if (e.status == 404) null else throw e
    }
}

@Serializable
private data class JellyfinLyricsReply(val lyrics: List<Line>? = null) {
    @Serializable data class Line(val start: Long? = null, val text: String? = null)
}

/** The server's own lyrics (embedded or sidecar files Jellyfin found). Untimed when any line has no start. */
suspend fun JellyfinClient.jellyfinLyrics(itemId: String): LyricsResult? = try {
    val reply: JellyfinLyricsReply = get("/Audio/$itemId/Lyrics")
    val lines = reply.lyrics.orEmpty().mapNotNull { l -> l.text?.trim()?.takeIf { it.isNotEmpty() }?.let { l.start to it } }
    if (lines.isEmpty()) null
    else LyricsResult(lines.map { LyricLine(it.first ?: 0, it.second) }, synced = lines.all { it.first != null }, source = "Jellyfin")
} catch (e: JellyfinException) {
    if (e.status == 404) null else throw e
}

/** How one source went on the last fetch, for the source menu's badges. */
enum class LyricsFetchStatus { Ok, Fail }

/** A fetch's answer and how each source it asked went (keyed "Kugou", "LRCLIB", "Jellyfin", or "Cascade" in server-only mode). */
data class LyricsOutcome(val result: LyricsResult? = null, val tried: Map<String, LyricsFetchStatus> = emptyMap())

/** The source pill's choices, stored under `cascade.lyricsForcedSource` with the desktop's strings. */
enum class LyricsSourceChoice(val raw: String) {
    Auto("auto"), Kugou("Kugou"), LRCLIB("LRCLIB"), Jellyfin("Jellyfin"), CascadeKaraoke("cascade-karaoke"), CascadeSynced("cascade-synced");

    val label: String get() = when (this) { Auto -> "Auto"; CascadeKaraoke -> "Karaoke"; CascadeSynced -> "Synced"; else -> raw }

    /** Server-only mode reads "Karaoke Only" and "Synced Only". */
    val menuLabel: String get() = when (this) { CascadeKaraoke -> "Karaoke Only"; CascadeSynced -> "Synced Only"; else -> label }

    /** What the plugin's `type` field must say for a forced server choice. */
    val pluginType: String? get() = when (this) { CascadeKaraoke -> "karaoke"; CascadeSynced -> "synced"; else -> null }

    /** Auto fits both modes; the server's files only server-only mode; the outside sources only the full waterfall. */
    fun isValid(serverOnly: Boolean): Boolean = when (this) {
        Auto -> true
        CascadeKaraoke, CascadeSynced -> serverOnly
        else -> !serverOnly
    }

    val statusKey: String? get() = when (this) { Auto -> null; CascadeKaraoke, CascadeSynced -> "Cascade"; else -> raw }

    companion object {
        const val KEY = "cascade.lyricsForcedSource"

        /** A stored value is untrusted: anything that is not one of these reads as Auto. */
        fun fromStored(stored: String?): LyricsSourceChoice = entries.firstOrNull { it.raw == stored } ?: Auto

        fun choices(serverOnly: Boolean) = entries.filter { it.isValid(serverOnly) }

        fun autoHint(serverOnly: Boolean) = if (serverOnly) "Server · karaoke preferred" else "Kugou → LRCLIB → Jellyfin"
    }
}

object LyricsWaterfall {
    data class Track(val id: String, val title: String, val artist: String, val album: String, val durationSeconds: Double) {
        companion object {
            fun of(item: JfItem) = Track(item.id, item.name ?: "", item.artists?.firstOrNull() ?: item.albumArtist ?: "",
                item.album ?: "", item.durationSeconds)
        }
    }

    /**
     * - plugin: null when it is absent (then server-only has nothing to ask, and is ignored).
     * - spotifyId: a link this user made for this song on this device only.
     * A forced source is asked alone (a forced Kugou never falls back to
     * LRCLIB), and SpicyLyrics is not a forceable choice, so forcing skips it.
     */
    suspend fun fetch(track: Track, client: JellyfinClient, plugin: CascadePluginState?, serverOnly: Boolean,
                      spotifyId: String?, userAgent: String, requested: LyricsSourceChoice = LyricsSourceChoice.Auto): LyricsOutcome {
        val http = client.httpClient
        val serverMode = serverOnly && plugin != null
        // A choice from the other mode is not one this mode can honor: it reads as Auto.
        val forced = if (requested.isValid(serverMode)) requested else LyricsSourceChoice.Auto

        if (serverMode && plugin != null) {
            val result = runCatching {
                client.serverLyrics(track.id, plugin.api, forced == LyricsSourceChoice.Auto && plugin.info.spicy,
                    track.durationSeconds, spotifyId, wantType = forced.pluginType)
            }.getOrNull()
            val kept = result?.let { r ->
                val lines = if (r.credit == null) Lyrics.droppingCredits(r.lines, track.title) else r.lines
                r.copy(lines = lines).takeIf { lines.isNotEmpty() }
            }
            return LyricsOutcome(kept, mapOf("Cascade" to if (kept == null) LyricsFetchStatus.Fail else LyricsFetchStatus.Ok))
        }

        suspend fun kugou(): LyricsResult? {
            val krc = runCatching { Kugou.krc(http, track.title, track.artist, (track.durationSeconds * 1000).toLong()) }.getOrNull()
                ?: return null
            val lines = Lyrics.droppingCredits(Lyrics.parseKrc(krc), track.title)
            // Only with word timings; otherwise LRCLIB's lines are as good.
            return if (lines.any { !it.words.isNullOrEmpty() }) LyricsResult(lines, source = "Kugou") else null
        }
        suspend fun lrclib(): LyricsResult? = runCatching {
            LRCLIB.lyrics(http, track.title, track.artist, track.album, Math.round(track.durationSeconds), userAgent)
        }.getOrNull()
        suspend fun jellyfin(): LyricsResult? = runCatching { client.jellyfinLyrics(track.id) }.getOrNull()

        if (forced != LyricsSourceChoice.Auto) {
            val result = when (forced) {
                LyricsSourceChoice.Kugou -> kugou()
                LyricsSourceChoice.LRCLIB -> lrclib()
                else -> jellyfin()
            }
            val tried = if (result?.instrumental == true) emptyMap()
            else mapOf(forced.raw to if (result == null) LyricsFetchStatus.Fail else LyricsFetchStatus.Ok)
            return LyricsOutcome(result, tried)
        }

        return coroutineScope {
            val spicy = async {
                if (plugin == null || !plugin.info.spicy) null
                else runCatching { client.serverLyrics(track.id, plugin.api, true, track.durationSeconds, spotifyId, spicyOnly = true) }.getOrNull()
            }
            val k = async { kugou() }
            val l = async { lrclib() }
            val j = async { jellyfin() }
            val (s, kr, lr, jr) = listOf(spicy.await(), k.await(), l.await(), j.await())
            if (lr?.instrumental == true) return@coroutineScope LyricsOutcome(lr)
            fun st(r: LyricsResult?) = if (r == null) LyricsFetchStatus.Fail else LyricsFetchStatus.Ok
            LyricsOutcome(s ?: kr ?: lr ?: jr, mapOf("Kugou" to st(kr), "LRCLIB" to st(lr), "Jellyfin" to st(jr)))
        }
    }
}

object Spotify {
    /**
     * The track id in whatever a person pastes: a share link (with or without
     * an /intl-xx/ or /embed/ segment and ?si=), a spotify:track: URI, or the
     * bare 22-character id. Null for anything else. The desktop's parseSpotifyTrackId.
     */
    fun trackId(input: String): String? {
        val s = input.trim()
        if (Regex("[A-Za-z0-9]{22}").matches(s)) return s
        Regex("spotify:track:([A-Za-z0-9]{22})").matchEntire(s)?.let { return it.groupValues[1] }
        Regex("(?i:(?:https?://)?open\\.spotify\\.com/(?:intl-[a-z-]+/)?(?:embed/)?track/)([A-Za-z0-9]{22})(?:[/?#].*)?")
            .matchEntire(s)?.let { return it.groupValues[1] }
        return null
    }
}

/** What a song is linked to on the server: its Spotify id, and whether a person set it. */
suspend fun JellyfinClient.spotifyLink(itemId: String): Pair<String?, Boolean> {
    val o = getJson("/CascadeServer/SpotifyId/$itemId").obj()
    return (o?.get("SpotifyId").str() ?: o?.get("spotifyId").str()) to ((o?.get("Manual") ?: o?.get("manual")).bool() == true)
}

/** Links a song to a Spotify track for everyone on the server. Throws the server's reason on a refusal. */
suspend fun JellyfinClient.setSpotifyLink(itemId: String, spotifyId: String) {
    postRaw("/CascadeServer/SpotifyId/$itemId", buildJsonObject { put("SpotifyId", spotifyId) }.toString())
}

