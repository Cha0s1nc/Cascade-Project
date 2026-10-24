package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlin.math.roundToLong

// SpicyLyrics API response -> Cascade's lyric lines, plus the credit the API's
// terms require wherever those lyrics are shown. Ported from the desktop's
// src/core/spicy-lyrics.ts through CascadeKit with its tests; keep them in step.
//
// These lyrics only ever reach the app through the Cascade Server plugin,
// which holds the server owner's own key. No key is ever in this app.
//
// Shape, from the reference's OpenAPI schema:
//   Body.Type 'Syllable' -> Content[] of { Lead: {Syllables[]}, Background?: [...] }
//   Body.Type 'Line'     -> Content[] of { Text, StartTime, EndTime }
//   Body.Type 'Static'   -> Lines[] of { Text }
// Every time is SECONDS as a float; Cascade keeps ticks. A Static sync has
// none, and comes back marked unsynced. OppositeAligned marks a duet's second
// voice. Deliberately not used: TranslatedText and TransliteratedText.

data class SpicyContributor(val name: String, /** https only: it came from a third party. */ val url: String? = null)

/** What the lyrics UI must show next to SpicyLyrics lyrics. Uploader and maker only exist for a community sync. */
data class SpicyCredit(val provider: String, val uploader: SpicyContributor? = null, val maker: SpicyContributor? = null)

data class SpicyConversion(val lines: List<LyricLine>, val credit: SpicyCredit, /** False for a Static sync. */ val synced: Boolean = true)

/** Reading untrusted JSON the way JSONSerialization's casts do in the Swift. */
internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
internal fun JsonElement?.arr(): List<JsonElement> = (this as? JsonArray).orEmpty()
internal fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
internal fun JsonElement?.num(): Double? =
    (this as? JsonPrimitive)?.takeIf { !it.isString && it.booleanOrNull == null }?.doubleOrNull
internal fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

object SpicyLyrics {
    private val providerLabels = mapOf(
        "spicy_lyrics" to "Spicy Lyrics",
        "apple_music" to "Apple Music via Spicy Lyrics",
        "spotify" to "Spotify via Spicy Lyrics",
    )

    /** How far past the end of the file a sync may run before it is taken to be for a different version. */
    const val END_TOLERANCE_SECONDS = 1.5

    /** The whole envelope or just its Body. */
    private fun body(raw: JsonElement?): JsonObject? {
        val o = raw.obj() ?: return null
        return o["Body"].obj() ?: o
    }

    /** Seconds to ticks, or null for anything that is not a usable time. */
    private fun ticks(v: JsonElement?): Long? =
        v.num()?.takeIf { it.isFinite() && it >= 0 }?.let { (it * Lyrics.TICKS_PER_SECOND_L).roundToLong() }

    fun safeCreditUrl(v: JsonElement?): String? {
        val s = v.str() ?: return null
        val url = s.toHttpUrlOrNull() ?: return null
        return if (url.scheme == "https" && url.host.isNotEmpty() && s.startsWith("https://", ignoreCase = true)) s else null
    }

    private fun contributor(v: JsonElement?): SpicyContributor? {
        val o = v.obj() ?: return null
        val name = (o["username"].str() ?: "").trim()
        return if (name.isEmpty()) null else SpicyContributor(name, safeCreditUrl(o["url"]))
    }

    /**
     * The credit for a response. Uploader and maker are read only for a
     * community sync, as the terms say; for a commercial source they are
     * absent even if sent.
     */
    fun credit(raw: JsonElement?): SpicyCredit {
        val b = body(raw) ?: JsonObject(emptyMap())
        val source = b["source"].str() ?: ""
        val attribution = if (source == "spicy_lyrics") b["UploadAttribution"].obj() else null
        return SpicyCredit(providerLabels[source] ?: "Spicy Lyrics", contributor(attribution?.get("Uploader")),
            contributor(attribution?.get("Maker")))
    }

    /**
     * One vocal group's syllables as words. IsPartOfWord joins a syllable to
     * the next with no space; otherwise a word carries its trailing space, as
     * parseLRC's do. Each syllable keeps its own end time, so the gaps between
     * words survive.
     */
    private fun groupWords(group: JsonElement?): List<LyricWord> {
        val g = group.obj() ?: return emptyList()
        val syllables = g["Syllables"].arr()
        val out = mutableListOf<LyricWord>()
        var prevEnd = ticks(g["StartTime"])
        syllables.forEachIndexed { i, raw ->
            val s = raw.obj() ?: return@forEachIndexed
            val text = s["Text"].str()?.takeIf { it.isNotEmpty() } ?: return@forEachIndexed
            // No time at all: it cannot be placed on the clock.
            val start = ticks(s["StartTime"]) ?: prevEnd ?: return@forEachIndexed
            val end = ticks(s["EndTime"])
            val joined = s["IsPartOfWord"].bool() == true || i == syllables.size - 1
            out += LyricWord(start, end, text + if (joined) "" else " ")
            prevEnd = end ?: start
        }
        return out
    }

    private fun opposite(c: JsonObject) = c["OppositeAligned"].bool() == true

    private fun syllableLines(content: List<JsonElement>): List<LyricLine> = content.mapNotNull { raw ->
        val c = raw.obj() ?: return@mapNotNull null
        val words = groupWords(c["Lead"])
        val first = words.firstOrNull() ?: return@mapNotNull null
        // Background vocals get a row of their own under the lead; merged in,
        // two fills ran across one line at once. Several phrases on a line
        // join into one row, each keeping its own timings.
        val background = mutableListOf<LyricWord>()
        for (bg in c["Background"].arr()) {
            val bw = groupWords(bg)
            if (bw.isEmpty()) continue
            if (background.isNotEmpty()) {
                val last = background.last()
                background[background.size - 1] = last.copy(text = last.text.trim() + " ")
            }
            background += bw
        }
        val text = words.joinToString("") { it.text }.trim()
        if (text.isEmpty()) null
        else LyricLine(ticks(c["Lead"].obj()?.get("StartTime")) ?: first.start, text, words,
            background.ifEmpty { null }, opposite(c))
    }

    private fun lineLines(content: List<JsonElement>): List<LyricLine> = content.mapNotNull { raw ->
        val c = raw.obj() ?: return@mapNotNull null
        val start = ticks(c["StartTime"]) ?: return@mapNotNull null
        val text = (c["Text"].str() ?: "").trim()
        if (text.isEmpty()) null else LyricLine(start, text, opposite = opposite(c))
    }

    /** Untimed lines, from Lines rather than Content. */
    private fun staticLines(list: List<JsonElement>): List<LyricLine> = list.mapNotNull { raw ->
        val text = (raw.obj()?.get("Text").str() ?: "").trim()
        if (text.isEmpty()) null else LyricLine(0, text)
    }

    /** Lines plus the credit to show, or null when there is nothing usable, so the caller falls back. */
    fun convert(raw: JsonElement?): SpicyConversion? {
        val b = body(raw) ?: return null
        val lines = when (b["Type"].str()) {
            "Syllable" -> syllableLines(b["Content"].arr())
            "Line" -> lineLines(b["Content"].arr())
            "Static" -> {
                val lines = staticLines(b["Lines"].arr())
                return if (lines.isEmpty()) null else SpicyConversion(lines, credit(b), synced = false)
            }
            else -> return null
        }
        return if (lines.isEmpty()) null else SpicyConversion(lines, credit(b))
    }

    /**
     * Whether a sync can belong to the file being played. A sync is keyed to a
     * Spotify track, and the id found can belong to another release whose
     * timings drift against this file. Vocals cannot end after the track does,
     * so a sync running past the file's end is another version: a 190.7 s sync
     * against a 186.6 s file ran 3.5 s late at the first verse. Only catches a
     * LONGER version. Nothing to judge passes.
     */
    fun fitsTrack(raw: JsonElement?, durationSeconds: Double): Boolean {
        val end = body(raw)?.get("EndTime").num() ?: return true
        if (!end.isFinite() || durationSeconds <= 0) return true
        return end <= durationSeconds + END_TOLERANCE_SECONDS
    }
}
