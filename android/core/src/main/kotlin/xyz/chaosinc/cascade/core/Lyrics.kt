package xyz.chaosinc.cascade.core

import kotlin.math.roundToLong

// Lyric parsing, ported from the desktop's src/core/lyrics.ts through
// CascadeKit's Lyrics.swift, along with their tests. Keep them in step: every
// branch below exists because a real file broke the version without it.
//
// All times are ticks, Jellyfin's convention: 100 ns, so 1 s = 10,000,000.

data class LyricWord(
    val start: Long,
    /** The next word's start; the last word of a line takes the next line's. */
    val end: Long?,
    val text: String,
)

data class LyricLine(
    val start: Long,
    val text: String,
    /** Null for plain LRC; set for karaoke (word-level) formats. */
    val words: List<LyricWord>? = null,
    /** Background vocals (SpicyLyrics), a smaller row under the lead with timings of their own. */
    val background: List<LyricWord>? = null,
    /** A duet's second voice (SpicyLyrics' OppositeAligned), drawn on the other side. */
    val opposite: Boolean = false,
)

object Lyrics {
    const val TICKS_PER_SECOND_L = 10_000_000L
    /** Used when the last line has no following line to borrow an end from. */
    internal const val LAST_WORD_FALLBACK_TICKS = 2 * TICKS_PER_SECOND_L

    // Rounded, like the desktop's Math.round: 10.53 * 1e7 is not exact in
    // floating point, and truncating would land a tick early.
    internal fun ticks(minutes: String, seconds: String): Long =
        (((minutes.toDoubleOrNull() ?: 0.0) * 60 + (seconds.toDoubleOrNull() ?: 0.0)) * TICKS_PER_SECOND_L).roundToLong()

    private fun hasLetterOrDigit(s: String) = s.any { it.isLetterOrDigit() }

    internal fun lines(text: String) = text.split(Regex("\r\n|\n|\r"))

    // Fractional seconds are optional. Requiring them silently dropped every
    // `[mm:ss]` line, a common style. Metadata tags ([ar:], [offset:]) still
    // fail the digits and are skipped.
    private val lineTag = Regex("\\[(\\d+):(\\d+(?:\\.\\d+)?)\\](.*)")
    private val wordTag = Regex("<(\\d+):(\\d+(?:\\.\\d+)?)>([^<\\[]*)")

    /**
     * Standard LRC (`[mm:ss.xx]text`) or Enhanced LRC, the karaoke format
     * (`[mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>word...`). `.slrc` files from the
     * Cascade Lyrics plugin are Enhanced LRC.
     */
    fun parseLRC(text: String): List<LyricLine> {
        val out = mutableListOf<LyricLine>()
        for (raw in lines(text)) {
            val m = lineTag.matchEntire(raw) ?: continue
            val start = ticks(m.groupValues[1], m.groupValues[2])
            val content = m.groupValues[3]
            if ('<' !in content) {
                val t = content.trim()
                if (t.isNotEmpty()) out += LyricLine(start, t)
                continue
            }
            val words = mutableListOf<LyricWord>()
            // Per-character sources (.slrc, Chinese karaoke) give every space its
            // own timestamped token; dropping those runs the whole line
            // together. Tracked separately so a word's own trailing space is
            // still trimmed before punctuation.
            var pendingSpace = false
            for (w in wordTag.findAll(content)) {
                val wText = w.groupValues[3]
                if (wText.isEmpty()) continue
                if (wText.isBlank()) { pendingSpace = words.isNotEmpty(); continue }
                // Punctuation with no letters or digits joins the previous word,
                // or karaoke shows a lone "!" as a lyric.
                if (!hasLetterOrDigit(wText) && words.isNotEmpty() && !pendingSpace) {
                    val prev = words.last()
                    words[words.size - 1] = prev.copy(text = prev.text.trimEnd() + wText.trimStart())
                } else {
                    if (pendingSpace) words[words.size - 1] = words.last().let { it.copy(text = it.text + " ") }
                    words += LyricWord(ticks(w.groupValues[1], w.groupValues[2]), null, wText)
                }
                pendingSpace = false
            }
            for (i in 0 until words.size - 1) words[i] = words[i].copy(end = words[i + 1].start)
            val full = words.joinToString("") { it.text }.trim()
            if (full.isNotEmpty()) out += LyricLine(start, full, words.ifEmpty { null })
        }
        // Each line's last word ends where the next line starts.
        for (i in out.indices) {
            val words = out[i].words ?: continue
            val last = words.last()
            if (last.end != null) continue
            val end = if (i + 1 < out.size) out[i + 1].start else last.start + LAST_WORD_FALLBACK_TICKS
            out[i] = out[i].copy(words = words.dropLast(1) + last.copy(end = end))
        }
        return out
    }

    /** Index of the line playing at `positionTicks`, or null before the first. */
    fun activeLineIndex(lines: List<LyricLine>, positionTicks: Long): Int? =
        lines.indexOfLast { it.start <= positionTicks }.takeIf { it >= 0 }

    /** A held note is at least this long. */
    const val EMPHASIS_MIN_TICKS = TICKS_PER_SECOND_L

    /**
     * Whether a word is a held note, to swell as it is sung: a second or
     * longer, and 1 to 12 letters or digits, one sung word rather than a
     * run-on syllable. Only meaningful for SpicyLyrics, whose syllables carry
     * real end times; parseLRC's end is the next word's start, so any word
     * before a pause would look held. The desktop's isEmphasisWord.
     */
    fun isEmphasisWord(w: LyricWord): Boolean {
        val end = w.end ?: return false
        if (end - w.start < EMPHASIS_MIN_TICKS) return false
        var letters = 0
        var i = 0
        while (i < w.text.length) {
            val cp = w.text.codePointAt(i)
            val t = Character.getType(cp)
            if (Character.isLetter(cp) || Character.isDigit(cp) || t == Character.LETTER_NUMBER.toInt() || t == Character.OTHER_NUMBER.toInt()) letters++
            i += Character.charCount(cp)
        }
        return letters in 1..12
    }

    /** Scripts written without spaces between words, where the "word" up to a space is the whole line. */
    private val noSpaceScript = Regex("[\\p{IsHan}\\p{IsHiragana}\\p{IsKatakana}\\p{IsThai}\\p{IsLao}\\p{IsKhmer}\\p{IsMyanmar}]")

    /**
     * A line's karaoke words in the units they are laid out in: each unit stays
     * on one row, so a word never wraps mid-way ("y / eah"). The desktop's
     * lyricWordSpans (lyric-karaoke.js), rule for rule:
     * - syllables up to a trailing space are one unit;
     * - with `emphasis`, a word holding a held syllable is held as a whole, one
     *   word from its first start to its last end, so the fill sweeps it evenly;
     * - scripts without spaces, and "words" over 30 characters, are not held
     *   together: each syllable is its own unit and wraps as the script does.
     */
    fun wordUnits(words: List<LyricWord>, emphasis: Boolean): List<List<LyricWord>> {
        val units = mutableListOf<List<LyricWord>>()
        val syllables = mutableListOf<LyricWord>()
        fun flush() {
            if (syllables.isEmpty()) return
            val whole = LyricWord(syllables.first().start, syllables.last().end, syllables.joinToString("") { it.text })
            val held = emphasis && syllables.size > 1 && syllables.any(::isEmphasisWord) && isEmphasisWord(whole)
            val parts = if (held) listOf(whole) else syllables.toList()
            val wordLike = !noSpaceScript.containsMatchIn(whole.text) && whole.text.trim().length <= 30
            if (wordLike) units += parts else parts.forEach { units += listOf(it) }
            syllables.clear()
        }
        for (w in words) {
            syllables += w
            if (w.text.lastOrNull()?.isWhitespace() == true) flush()
        }
        flush()
        return units
    }

    /** How far through a karaoke word the fill is at `positionTicks`, 0 to 1. The desktop's _wordProgress. */
    fun wordProgress(word: LyricWord, positionTicks: Long): Double {
        if (positionTicks < word.start) return 0.0
        val end = word.end ?: return 1.0
        if (positionTicks >= end || end <= word.start) return 1.0
        return (positionTicks - word.start).toDouble() / (end - word.start)
    }

    /**
     * A line's signed distance from the current one: 0 is current, positive is
     * upcoming, negative is past. Before the first line starts, every line
     * counts as upcoming from an imaginary line -1, so the first line waits one
     * step away rather than looking already past.
     */
    fun lineDistance(index: Int, active: Int?): Int = index - (active ?: -1)

    private fun lastEnd(words: List<LyricWord>?): Long? = words?.lastOrNull()?.end

    /** When a line is sung to: the later of its last word's end and its last background word's. Null for plain LRC. */
    fun lineEndTicks(line: LyricLine): Long? = listOfNotNull(lastEnd(line.words), lastEnd(line.background)).maxOrNull()

    /** How close a line must follow the one before to count as tight. */
    const val TIGHT_GAP_TICKS = TICKS_PER_SECOND_L / 2

    /**
     * The line after `index` when it is tight (starts within TIGHT_GAP_TICKS of
     * the line's end, without overlapping it) and starts within `lead` from
     * now, so it can light and be scrolled to early: back-to-back lines would
     * otherwise arrive late. The desktop's tightScrollTarget.
     */
    fun tightNextIndex(lines: List<LyricLine>, after: Int, now: Long, lead: Long): Int? {
        if (lead <= 0 || after !in lines.indices || after + 1 >= lines.size) return null
        val end = lineEndTicks(lines[after]) ?: return null
        val next = lines[after + 1].start
        val gap = next - end
        return if (gap in 0..TIGHT_GAP_TICKS && next - now <= lead) after + 1 else null
    }

    /**
     * Which line is current, given `base` (the last one already started): once
     * a karaoke line is completely sung, background vocals included, the next
     * one is, rather than sitting dim until its own start.
     */
    fun currentLineIndex(lines: List<LyricLine>, base: Int, now: Long): Int {
        if (base !in lines.indices || base + 1 >= lines.size || lines[base].words.isNullOrEmpty()) return base
        val lead = lastEnd(lines[base].words) ?: return base
        val end = maxOf(lead, lastEnd(lines[base].background) ?: lead)
        return if (now >= end) base + 1 else base
    }

    /**
     * The lines to light as current around `index`. When a line starts while
     * the one before is still being sung (a duet, a call and response, a
     * background vocal running on), both stay lit until all of the group is
     * sung, as Apple Music does. Only lines still sung when the current one
     * began, not a chain of overlaps.
     */
    fun activeRange(lines: List<LyricLine>, index: Int, now: Long): IntRange {
        if (index !in lines.indices) return index..index
        val current = lines[index]
        var first = index
        var groupEnd = lineEndTicks(current) ?: Long.MIN_VALUE
        while (first > 0) {
            val previousEnd = lineEndTicks(lines[first - 1]) ?: break
            if (current.start >= previousEnd) break
            first -= 1
            groupEnd = maxOf(groupEnd, previousEnd)
        }
        return if (first < index && now < groupEnd) first..index else index..index
    }

    /** Signed distance from the current group: negative is past, positive upcoming, 0 any line in the group. */
    fun lineDistance(index: Int, group: IntRange?): Int {
        group ?: return index + 1
        return when {
            index < group.first -> index - group.first
            index > group.last -> index - group.last
            else -> 0
        }
    }
}

// Cascade Lyrics / Cascade Server plugin.

/**
 * Which route family the server's plugin answers on. The plugin was called
 * Cascade Lyrics before 2.0.0.0 (routes CascadeLyrics/...); it is Cascade
 * Server from then on (CascadeServer/...). From src/core/cascade-plugin.ts.
 */
enum class CascadePluginApi { Server, Legacy }

enum class CascadePluginProbe { Present, Absent, Unknown }

object CascadePlugin {
    /**
     * 200 means the plugin said so, 404 means the route (so the plugin) is
     * missing. Anything else (401, 5xx, no network) says nothing, and callers
     * treat it as present: never hide a working feature over a network hiccup.
     */
    fun interpret(status: Int?): CascadePluginProbe = when (status) {
        200 -> CascadePluginProbe.Present
        404 -> CascadePluginProbe.Absent
        else -> CascadePluginProbe.Unknown
    }

    /** Combines the new-route probe with the old one, which is only asked when the new one said 404. */
    fun resolve(serverStatus: Int?, legacyStatus: Int?): Pair<CascadePluginProbe, CascadePluginApi> {
        val first = interpret(serverStatus)
        if (first != CascadePluginProbe.Absent) return first to CascadePluginApi.Server
        return interpret(legacyStatus) to CascadePluginApi.Legacy
    }

    fun lyricsPath(api: CascadePluginApi, itemId: String): String =
        if (api == CascadePluginApi.Legacy) "/Audio/$itemId/CascadeLyrics" else "/CascadeServer/Lyrics/$itemId"
}
