package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.PI
import kotlin.math.cos

// The full-screen lyrics' look, as numbers: the iPhone's Style Tuning values
// (apple/App/Sources/StyleTuning.swift) and the desktop's lyric-style.ts, which
// share their keys, so a look can move between the apps. Stored like the
// Apple app's `cascade.styleTuning`: only the knobs a person changed, as a JSON
// object of key to number. Stored values are untrusted and clamped.

data class LyricKnob(val key: String, val section: String, val label: String, val min: Double, val max: Double,
                     val step: Double, /** The shipped look: the iPhone's default. */ val value: Double)

object LyricStyle {
    const val STORE_KEY = "cascade.styleTuning"

    val knobs: List<LyricKnob> = listOf(
        // Negative is earlier: a line takes its fade to light up, so one drawn
        // exactly on the beat reads as late. Apple Music leads too.
        LyricKnob("lyricsDelay", "Lyrics layout", "Lyrics timing (s)", -2.0, 2.0, 0.05, -0.05),
        LyricKnob("scrollLead", "Lyrics layout", "Scroll ahead (s)", 0.0, 1.0, 0.05, 0.0),
        LyricKnob("tightScrollLead", "Lyrics layout", "Scroll ahead on tight lines (s)", 0.0, 1.0, 0.05, 0.25),
        LyricKnob("lyricSize", "Lyrics layout", "Text size", 18.0, 60.0, 1.0, 30.0),
        // A phone keeps the current line high, as Apple Music does; the
        // desktop centres it (0.5).
        LyricKnob("currentLinePosition", "Lyrics layout", "Current line position", 0.0, 0.6, 0.01, 0.12),
        LyricKnob("lineGap", "Lyrics layout", "Line gap", 0.0, 40.0, 1.0, 8.0),
        LyricKnob("pastScale", "Past lines", "Size", 0.4, 1.0, 0.01, 0.75),
        LyricKnob("pastOpacity", "Past lines", "Opacity", 0.0, 1.0, 0.01, 0.3),
        LyricKnob("pastBlur", "Past lines", "Blur", 0.0, 8.0, 0.5, 3.5),
        LyricKnob("next1Opacity", "Upcoming lines", "Next opacity", 0.0, 1.0, 0.01, 0.15),
        LyricKnob("next1Blur", "Upcoming lines", "Next blur", 0.0, 8.0, 0.5, 2.5),
        LyricKnob("next2Opacity", "Upcoming lines", "Second opacity", 0.0, 1.0, 0.01, 0.11),
        LyricKnob("next2Blur", "Upcoming lines", "Second blur", 0.0, 8.0, 0.5, 4.0),
        LyricKnob("next3Opacity", "Upcoming lines", "Third opacity", 0.0, 1.0, 0.01, 0.1),
        LyricKnob("next3Blur", "Upcoming lines", "Third blur", 0.0, 8.0, 0.5, 4.0),
        LyricKnob("farBlur", "Upcoming lines", "Blur further out", 0.0, 12.0, 0.5, 6.0),
        LyricKnob("browsingBlur", "Upcoming lines", "Blur while scrolling", 0.0, 8.0, 0.5, 2.5),
        LyricKnob("browsingOpacity", "Upcoming lines", "Opacity while scrolling", 0.0, 1.0, 0.01, 0.8),
        LyricKnob("unsungOpacity", "Karaoke", "Unsung word opacity", 0.0, 1.0, 0.01, 0.29),
        LyricKnob("wordLift", "Karaoke", "Word lift (em)", 0.0, 0.2, 0.005, 0.04),
        LyricKnob("heldFullSeconds", "Karaoke", "Held note: full swell after (s)", 1.0, 8.0, 0.1, 1.4),
        LyricKnob("heldMinStrength", "Karaoke", "Held note: short note strength", 0.0, 1.0, 0.05, 0.45),
        LyricKnob("heldLift", "Karaoke", "Held note lift (em)", 0.0, 0.4, 0.01, 0.16),
        LyricKnob("heldScale", "Karaoke", "Held note swell", 1.0, 1.4, 0.01, 1.19),
        LyricKnob("heldSettleSeconds", "Karaoke", "Held note release time (s)", 0.0, 2.0, 0.05, 0.4),
        LyricKnob("backgroundVocalSize", "Karaoke", "Background vocal size", 0.4, 1.0, 0.01, 0.64),
        LyricKnob("backgroundVocalOpacity", "Karaoke", "Background vocal opacity", 0.0, 1.0, 0.01, 0.85),
        LyricKnob("fadeSeconds", "Motion", "Line fade (s)", 0.0, 2.0, 0.05, 1.0),
        LyricKnob("rippleSeconds", "Motion", "Ripple per line (s)", 0.0, 0.4, 0.01, 0.04),
    )

    private val byKey = knobs.associateBy { it.key }

    fun knob(key: String): LyricKnob? = byKey[key]

    val defaults: Map<String, Double> = knobs.associate { it.key to it.value }

    /** Every knob's value: the stored ones, clamped, over the defaults. Anything else is ignored. */
    fun fromStored(raw: String?): Map<String, Double> {
        val obj = raw?.let { runCatching { PlainJson.parseToJsonElement(it) }.getOrNull() } as? JsonObject ?: return defaults
        return knobs.associate { k ->
            val v = obj[k.key].num()?.takeIf { it.isFinite() }
            k.key to (v?.coerceIn(k.min, k.max) ?: k.value)
        }
    }

    /** Only what differs from the defaults, so a better default later still reaches what was left alone. */
    fun stored(values: Map<String, Double>): String =
        JsonObject(knobs.mapNotNull { k ->
            val v = values[k.key] ?: return@mapNotNull null
            if (v == k.value) null else k.key to JsonPrimitive(v.coerceIn(k.min, k.max))
        }.toMap()).toString()
}

/** Opacity, blur (points) and size share for a line `distance` from the current one. */
data class LineLook(val opacity: Double, val blur: Double, val scale: Double)

/** The values the lyrics are drawn with, read once per change rather than per frame. */
class LyricTuning(private val v: Map<String, Double> = LyricStyle.defaults) {
    operator fun get(key: String): Double = v[key] ?: LyricStyle.defaults.getValue(key)

    /**
     * The iPhone's line looks: the current line full, the next three fading
     * out, everything further hidden, past lines shrunk and dim so the song so
     * far reads as context. Scrolling by hand shows every line nearly full.
     */
    fun look(distance: Int, browsing: Boolean): LineLook {
        if (browsing) return if (distance == 0) LineLook(1.0, 0.0, 1.0) else LineLook(this["browsingOpacity"], this["browsingBlur"], 1.0)
        return when {
            distance < 0 -> LineLook(this["pastOpacity"], this["pastBlur"], this["pastScale"])
            distance == 0 -> LineLook(1.0, 0.0, 1.0)
            distance == 1 -> LineLook(this["next1Opacity"], this["next1Blur"], 1.0)
            distance == 2 -> LineLook(this["next2Opacity"], this["next2Blur"], 1.0)
            distance == 3 -> LineLook(this["next3Opacity"], this["next3Blur"], 1.0)
            else -> LineLook(0.0, this["farBlur"], 1.0)
        }
    }

    /**
     * How swollen a held note's letter is, 0 to 1 of the full swell. Apple
     * Music swells a held note more the longer it is: the strength comes from
     * the note's length (a 1 s hold gets heldMinStrength, heldFullSeconds or
     * longer all of it), each letter rises from when the fill reaches it until
     * the note ends, then eases back over heldSettleSeconds. A letter reached
     * near the end still rises over at least 0.35 s rather than popping.
     */
    fun swell(sinceLit: Double, untilEnd: Double, held: Double): Double {
        if (sinceLit < 0) return 0.0
        val full = this["heldFullSeconds"]
        val minStrength = this["heldMinStrength"]
        val reach = if (full > 1) ((held - 1) / (full - 1)).coerceIn(0.0, 1.0) else 1.0
        val strength = minStrength + (1 - minStrength) * reach
        val rise = maxOf(untilEnd, 0.35)
        if (sinceLit < rise) return strength * easeInOut(sinceLit / rise)
        val settleSeconds = this["heldSettleSeconds"]
        val settle = if (settleSeconds > 0) minOf(1.0, (sinceLit - rise) / settleSeconds) else 1.0
        return strength * (1 - easeInOut(settle))
    }

    private fun easeInOut(t: Double): Double = (1 - cos(PI * t.coerceIn(0.0, 1.0))) / 2
}
