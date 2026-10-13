package xyz.chaosinc.cascade.android.ui

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import xyz.chaosinc.cascade.core.LyricLine
import xyz.chaosinc.cascade.core.LyricTuning
import xyz.chaosinc.cascade.core.LyricWord
import xyz.chaosinc.cascade.core.Lyrics
import xyz.chaosinc.cascade.core.LyricsResult
import xyz.chaosinc.cascade.core.SpicyCredit
import xyz.chaosinc.cascade.core.ticksFromMs
import kotlin.math.roundToInt

// The iPhone's karaoke lyrics (LyricsView.swift), itself the desktop's Now
// Playing lyrics carried over value for value: the current line full white
// and held high, the next three fading out with blur, past lines shrunk and
// dim, karaoke words filling behind a soft edge and lifting once reached,
// held notes swelling letter by letter, duets on opposite sides, background
// vocals in a smaller row under their line, overlapping lines lit together.
// Every value comes from LyricTuning (core), so the look matches the iPhone's.

private val fadeEasing = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)
private val liftEasing = CubicBezierEasing(0.25f, 0.8f, 0.25f, 1f)

/** How long scrolling by hand holds before the lyrics spring back to the current line, as on the iPhone. */
private const val SETTLE_MS = 2_500L

/**
 * The lyrics for the playing track. `positionMs` is read every frame while
 * playing (the player's own clock, not a half-second tick), so a line changes
 * on its beat. A tapped line seeks to it.
 */
@Composable
fun LyricsView(
    result: LyricsResult,
    tuning: LyricTuning,
    positionMs: () -> Long,
    playing: Boolean,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val lines = result.lines
    val synced = result.synced
    // Held notes only for SpicyLyrics: only its syllables carry real ends.
    val emphasis = result.credit != null
    var now by remember { mutableLongStateOf(0L) }
    LaunchedEffect(playing, synced) {
        val delayTicks = (tuning["lyricsDelay"] * 10_000_000).toLong()
        now = ticksFromMs(positionMs()) - delayTicks
        if (!synced) return@LaunchedEffect
        while (true) {
            withFrameNanos { }
            now = ticksFromMs(positionMs()) - delayTicks
            if (!playing) { delay(250) }
        }
    }

    // The current line and the group lit with it (the desktop's
    // currentLyricIndex and activeLyricRange), a tight next line taking over early.
    val tight = (tuning["tightScrollLead"] * 10_000_000).toLong()
    val base = if (synced) Lyrics.activeLineIndex(lines, now) else null
    val active = base?.let { b -> Lyrics.currentLineIndex(lines, b, now).let { Lyrics.tightNextIndex(lines, it, now, tight) ?: it } }
    val group = active?.let { Lyrics.activeRange(lines, it, now) }

    val listState = rememberLazyListState()
    var browsing by remember { mutableStateOf(false) }
    val interactions = listState.interactionSource
    LaunchedEffect(interactions) {
        interactions.interactions.collect { if (it is DragInteraction.Start) browsing = true }
    }
    // Springs back once the hand has been off the list for a moment.
    LaunchedEffect(browsing, listState.isScrollInProgress) {
        if (browsing && !listState.isScrollInProgress) { delay(SETTLE_MS); browsing = false }
    }

    val density = LocalDensity.current
    val size = tuning["lyricSize"]
    BoxWithConstraints(modifier.fillMaxSize()) {
        val anchorPx = with(density) { (maxHeight * tuning["currentLinePosition"].toFloat()).roundToPx() }
        val target = group?.first ?: active ?: 0
        LaunchedEffect(target, browsing, anchorPx) {
            if (!synced || browsing) return@LaunchedEffect
            // A group scrolls as one block from its first line, so the earlier
            // singer is not pushed off the top while still being sung.
            val info = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == target }
            if (info != null) listState.animateScrollBy((info.offset - anchorPx).toFloat(), tween(600, easing = fadeEasing))
            else listState.animateScrollToItem(target, -anchorPx)
        }
        LazyColumn(state = listState, contentPadding = PaddingValues(start = 24.dp, end = 24.dp, bottom = maxHeight)) {
            itemsIndexed(lines, key = { i, _ -> i }) { i, line ->
                val distance = if (!synced) 0 else Lyrics.lineDistance(i, group)
                LyricLineView(line, distance, browsing, emphasis, tuning, size, if (distance == 0) now else Long.MIN_VALUE,
                    onClick = if (synced) ({ onSeek(line.start / 10_000) }) else null)
            }
            result.credit?.let { credit -> item { CreditLine(credit) } }
        }
    }
}

@Composable
private fun CreditLine(credit: SpicyCredit) {
    // Their terms want the source on screen wherever these lyrics show.
    val text = buildString {
        append(credit.provider)
        credit.uploader?.let { append(" · Uploaded by ${it.name}") }
        credit.maker?.let { append(" · Synced by ${it.name}") }
    }
    Text(text, color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LyricLineView(
    line: LyricLine, distance: Int, browsing: Boolean, emphasis: Boolean, tuning: LyricTuning, size: Double, now: Long,
    onClick: (() -> Unit)?,
) {
    val look = tuning.look(distance, browsing)
    val fadeMs = (tuning["fadeSeconds"] * 1000).roundToInt()
    // Upcoming lines settle in one after another (the desktop's ripple).
    val rippleMs = if (distance > 0) (minOf(distance, 3) * tuning["rippleSeconds"] * 1000).roundToInt() else 0
    val opacity by animateFloatAsState(look.opacity.toFloat(), tween(fadeMs, rippleMs, fadeEasing), label = "opacity")
    val blur by animateFloatAsState(look.blur.toFloat(), tween(fadeMs, rippleMs, fadeEasing), label = "blur")
    val scale by animateFloatAsState(look.scale.toFloat(), tween(fadeMs, 0, fadeEasing), label = "scale")
    val end = line.opposite
    val style = TextStyle(fontSize = size.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.015).em,
        lineHeight = (size * 1.2).sp, textAlign = if (end) TextAlign.End else TextAlign.Start)
    val gap = (tuning["lineGap"] * scale).dp
    Column(
        Modifier.fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClick) else Modifier)
            .padding(vertical = gap)
            // A duet's second voice sits in from the right edge, so it reads as the other singer.
            .padding(start = if (end) (size * 0.8).dp else 0.dp, end = if (end) 0.dp else 0.dp)
            .graphicsLayer {
                alpha = opacity
                scaleX = scale; scaleY = scale
                transformOrigin = TransformOrigin(if (end) 1f else 0f, 0f)
            }
            .blur(blur.dp),
        horizontalAlignment = if (end) Alignment.End else Alignment.Start,
    ) {
        val words = line.words
        if (words.isNullOrEmpty()) {
            Text(line.text, style = style, color = Color.White, modifier = Modifier.fillMaxWidth())
        } else {
            WordFlow(words, now, emphasis, tuning, style, end)
            val background = line.background
            if (background != null && distance == 0) {
                // Background vocals: a smaller, quieter row under the line while it is current.
                val bgSize = size * tuning["backgroundVocalSize"]
                Box(Modifier.padding(top = (bgSize * 0.3).dp).graphicsLayer { alpha = tuning["backgroundVocalOpacity"].toFloat() }) {
                    WordFlow(background, now, emphasis, tuning, style.copy(fontSize = bgSize.sp, lineHeight = (bgSize * 1.2).sp,
                        fontWeight = FontWeight.SemiBold), end)
                }
            }
        }
    }
}

/** Words in their layout units (Lyrics.wordUnits): a unit never wraps inside itself, and a held note swells letter by letter. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WordFlow(words: List<LyricWord>, now: Long, emphasis: Boolean, tuning: LyricTuning, style: TextStyle, end: Boolean) {
    val units = remember(words, emphasis) { Lyrics.wordUnits(words, emphasis) }
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = if (end) Arrangement.End else Arrangement.Start) {
        for (unit in units) {
            Row {
                for (word in unit) {
                    if (emphasis && Lyrics.isEmphasisWord(word)) HeldWord(word, now, tuning, style)
                    else KaraokeWord(word.text, Lyrics.wordProgress(word, now).toFloat(), now >= word.start, tuning, style)
                }
            }
        }
    }
}

/**
 * One karaoke word: dim, filled with white up to its progress behind a soft
 * edge 0.6 em wide, lifted a little once the fill has reached it. The edge's
 * centre slides from 0.3 em before the word to 0.3 em past it, so an unsung
 * word is fully dim and a sung one fully lit (lyric-karaoke.js's --p).
 */
@Composable
private fun KaraokeWord(text: String, progress: Float, sung: Boolean, tuning: LyricTuning, style: TextStyle, glow: Float = 0f) {
    val sizePx = with(LocalDensity.current) { style.fontSize.toPx() }
    val lift by animateFloatAsState(if (sung) (tuning["wordLift"] * sizePx).toFloat() else 0f, tween(600, easing = liftEasing), label = "lift")
    val unsung = Color.White.copy(alpha = tuning["unsungOpacity"].toFloat())
    val edge = 0.3f * sizePx
    Box(Modifier.graphicsLayer { translationY = -lift }) {
        Text(text, style = style.copy(textAlign = TextAlign.Start), color = unsung, softWrap = false)
        Text(text, style = style.copy(textAlign = TextAlign.Start,
            shadow = if (glow > 0f) Shadow(Color.White.copy(alpha = 0.7f * glow), Offset.Zero, 0.35f * sizePx * glow) else null),
            color = Color.White, softWrap = false,
            modifier = Modifier.graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }.drawWithContent {
                drawContent()
                val width = size.width.coerceAtLeast(1f)
                val centre = progress * width + (progress * 2 - 1) * edge
                drawRect(Brush.horizontalGradient(0f to Color.White, 1f to Color.Transparent,
                    startX = centre - edge, endX = centre + edge), blendMode = BlendMode.DstIn)
            })
    }
}

/**
 * A held note, letter by letter as Apple Music draws it: the fill sweeps the
 * letters in turn, and each one rises, swells and glows from when the fill
 * reaches it (LyricTuning.swell). Held notes skip the ordinary word lift.
 */
@Composable
private fun HeldWord(word: LyricWord, now: Long, tuning: LyricTuning, style: TextStyle) {
    val sizePx = with(LocalDensity.current) { style.fontSize.toPx() }
    val letters = word.text.trim()
    val n = maxOf(letters.length, 1)
    val progress = Lyrics.wordProgress(word, now)
    val start = word.start / 1e7
    val held = ((word.end ?: word.start) - word.start) / 1e7
    val seconds = now / 1e7
    Row(Modifier.padding(horizontal = (0.06 * style.fontSize.value).dp)) {
        letters.forEachIndexed { i, c ->
            val litAt = start + held * i / n
            val s = if (now == Long.MIN_VALUE) 0.0 else tuning.swell(seconds - litAt, start + held - litAt, held)
            Box(Modifier.graphicsLayer {
                val k = (1 + (tuning["heldScale"] - 1) * s).toFloat()
                scaleX = k; scaleY = k
                transformOrigin = TransformOrigin(0.5f, 0.75f)
                translationY = -(tuning["heldLift"] * sizePx * s).toFloat()
            }) {
                KaraokeWord(c.toString(), (progress * n - i).coerceIn(0.0, 1.0).toFloat(), false, tuning, style, glow = s.toFloat())
            }
        }
        if (word.text.lastOrNull()?.isWhitespace() == true) Text(" ", style = style)
    }
}

