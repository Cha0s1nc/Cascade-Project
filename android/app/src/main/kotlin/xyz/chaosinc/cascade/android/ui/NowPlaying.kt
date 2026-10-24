package xyz.chaosinc.cascade.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Lyrics
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.LyricStyle
import xyz.chaosinc.cascade.core.LyricTuning
import xyz.chaosinc.cascade.core.LyricsSourceChoice
import xyz.chaosinc.cascade.core.RepeatMode
import xyz.chaosinc.cascade.core.setFavorite

/** The player's position, refreshed twice a second while something plays: enough for a scrubber. */
@Composable
private fun rememberPosition(): Long {
    val engine = appState.engine
    val playing = engine.state.collectAsState().value.isPlaying
    var position by remember { mutableLongStateOf(engine.player.currentPosition) }
    LaunchedEffect(playing) {
        while (true) {
            position = engine.player.currentPosition
            if (!playing) break
            delay(500)
        }
    }
    return position
}

/** The bar above the tabs: art, title, play or pause, next. Tap opens Now Playing. */
@Composable
fun MiniPlayer(onOpen: () -> Unit) {
    val engine = appState.engine
    val state by engine.state.collectAsState()
    val item = state.current ?: return
    val position = rememberPosition()
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Column {
            val duration = state.durationMs.coerceAtLeast(1)
            LinearProgressIndicator(progress = { (position.toFloat() / duration).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth().height(2.dp),
                drawStopIndicator = {})
            Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Artwork(item.artItemId, 44.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(item.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold)
                    Text(item.artistLine, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (state.buffering && state.isPlaying.not()) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                IconButton(onClick = engine::togglePlayPause) {
                    Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (state.isPlaying) "Pause" else "Play")
                }
                IconButton(onClick = engine::next) { Icon(Icons.Default.SkipNext, "Next") }
            }
        }
    }
}

private enum class NowPlayingMode { Artwork, Lyrics, Queue }

/**
 * The full player, after the iPhone's: big artwork with the title, a heart and
 * a menu under it, a scrubber, transport, and a bottom bar of lyrics and
 * queue. Lyrics and the queue take the artwork's place, which shrinks into a
 * header, rather than opening screens of their own.
 */
@Composable
fun NowPlayingScreen(nav: Nav, onClose: () -> Unit) {
    val engine = appState.engine
    val state by engine.state.collectAsState()
    val item = state.current
    BackHandler(onBack = onClose)
    LaunchedEffect(item == null) { if (item == null) onClose() }
    item ?: return
    var mode by remember { mutableStateOf(NowPlayingMode.Artwork) }
    val tuning = remember { LyricTuning(LyricStyle.fromStored(appState.settings.string(LyricStyle.STORE_KEY))) }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        // The cover, blurred far past recognition, as the background. Android
        // blurs from 12 on; older phones get it dimmed instead.
        Artwork(item.artItemId, 600.dp, Modifier.fillMaxSize().blur(80.dp), corner = 0.dp)
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = if (mode == NowPlayingMode.Artwork) 0.45f else 0.6f)))
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp)) {
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.Default.KeyboardArrowDown, "Close", tint = Color.White) }
                Spacer(Modifier.weight(1f))
            }
            AnimatedContent(mode, label = "mode", modifier = Modifier.weight(1f)) { m ->
                when (m) {
                    NowPlayingMode.Artwork -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
                        val scale by androidx.compose.animation.core.animateFloatAsState(if (state.isPlaying) 1f else 0.88f, label = "breathe")
                        Box(Modifier.fillMaxWidth().aspectRatio(1f), contentAlignment = Alignment.Center) {
                            // Breathes with playback, as Apple's does: full size playing, eased back paused.
                            Box(Modifier.fillMaxSize(scale)) { Artwork(item.artItemId, 360.dp, Modifier.fillMaxSize(), corner = 12.dp) }
                        }
                    }
                    NowPlayingMode.Lyrics -> Column(Modifier.fillMaxSize()) {
                        CompactHeader(item)
                        LyricsPane(item, tuning)
                    }
                    NowPlayingMode.Queue -> Column(Modifier.fillMaxSize()) {
                        CompactHeader(item)
                        QueueList()
                    }
                }
            }
            if (mode == NowPlayingMode.Artwork) TitleRow(item, nav, onClose)
            Scrubber(state.durationMs)
            Transport()
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                IconButton(onClick = { mode = if (mode == NowPlayingMode.Lyrics) NowPlayingMode.Artwork else NowPlayingMode.Lyrics }) {
                    Icon(Icons.Default.Lyrics, "Lyrics", tint = if (mode == NowPlayingMode.Lyrics) MaterialTheme.colorScheme.primary else Color.White)
                }
                IconButton(onClick = { mode = if (mode == NowPlayingMode.Queue) NowPlayingMode.Artwork else NowPlayingMode.Queue }) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, "Queue", tint = if (mode == NowPlayingMode.Queue) MaterialTheme.colorScheme.primary else Color.White)
                }
            }
        }
    }
}

@Composable
private fun CompactHeader(item: JfItem) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Artwork(item.artItemId, 56.dp)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(item.name ?: "", color = Color.White, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(item.artistLine, color = Color.White.copy(alpha = 0.7f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun TitleRow(item: JfItem, nav: Nav, onClose: () -> Unit) {
    val client = currentClient()
    val scope = rememberCoroutineScope()
    var favorite by remember(item.id) { mutableStateOf(item.isFavorite) }
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(item.name ?: "", style = MaterialTheme.typography.titleLarge, color = Color.White, fontWeight = FontWeight.Bold,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(item.artistLine, style = MaterialTheme.typography.titleMedium, color = Color.White.copy(alpha = 0.7f), maxLines = 1,
                overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = {
            val want = !favorite
            scope.launch {
                // Flips only once the server has taken it.
                if (runCatching { withContext(Dispatchers.IO) { client?.setFavorite(want, item.id) } }.isSuccess) favorite = want
            }
        }) { Icon(if (favorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder, "Favorite", tint = Color.White) }
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreHoriz, "More", tint = Color.White) }
            TrackMenu(item, menu, { menu = false }, TrackActions(
                openAlbum = { onClose(); nav.album(it) }, openArtist = { onClose(); nav.artist(it) }))
        }
    }
}

/** A scrubber that owns its value while dragged; the seek happens on release, not on every movement. */
@Composable
private fun Scrubber(durationMs: Long) {
    val engine = appState.engine
    val position = rememberPosition()
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }
    val duration = durationMs.coerceAtLeast(1)
    val shown = if (dragging) dragValue else (position.toFloat() / duration).coerceIn(0f, 1f)
    Column(Modifier.padding(top = 8.dp)) {
        Slider(value = shown, onValueChange = { dragging = true; dragValue = it },
            onValueChangeFinished = { engine.seekTo((dragValue * duration).toLong()); dragging = false },
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.25f)))
        Row(Modifier.fillMaxWidth()) {
            Text(formatDuration(shown * duration / 1000.0), color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.weight(1f))
            Text("-" + formatDuration((duration - shown * duration) / 1000.0), color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun Transport() {
    val engine = appState.engine
    val state by engine.state.collectAsState()
    val accent = MaterialTheme.colorScheme.primary
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { engine.setShuffled(!state.shuffled) }) {
            Icon(Icons.Default.Shuffle, "Shuffle", tint = if (state.shuffled) accent else Color.White.copy(alpha = 0.8f))
        }
        IconButton(onClick = engine::previous, modifier = Modifier.size(56.dp)) { Icon(Icons.Default.SkipPrevious, "Previous", Modifier.size(40.dp), tint = Color.White) }
        IconButton(onClick = engine::togglePlayPause, modifier = Modifier.size(72.dp)) {
            Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (state.isPlaying) "Pause" else "Play",
                Modifier.size(56.dp), tint = Color.White)
        }
        IconButton(onClick = engine::next, modifier = Modifier.size(56.dp)) { Icon(Icons.Default.SkipNext, "Next", Modifier.size(40.dp), tint = Color.White) }
        IconButton(onClick = engine::cycleRepeat) {
            Icon(if (state.repeat == RepeatMode.One) Icons.Default.RepeatOne else Icons.Default.Repeat, "Repeat",
                tint = if (state.repeat == RepeatMode.None) Color.White.copy(alpha = 0.8f) else accent)
        }
    }
    state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
}

@Composable
private fun LyricsPane(item: JfItem, tuning: LyricTuning) {
    val app = appState
    val model = app.lyrics
    val plugin by app.plugin.collectAsState()
    val serverOnly by app.serverOnlyLyrics.collectAsState()
    var forced by remember { mutableStateOf(model.forced) }
    LaunchedEffect(item.id, plugin, serverOnly, forced) { model.load(item) }
    val lyrics by model.state.collectAsState()
    val engine = app.engine
    val playing = engine.state.collectAsState().value.isPlaying
    var sourceMenu by remember { mutableStateOf(false) }
    val serverMode = serverOnly && plugin != null
    Column(Modifier.fillMaxSize()) {
        Box {
            val result = lyrics.outcome?.result
            Text((if (forced == LyricsSourceChoice.Auto) result?.source ?: "Lyrics" else forced.label) + "  ▾",
                color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.clickable { sourceMenu = true }.padding(vertical = 4.dp))
            DropdownMenu(sourceMenu, { sourceMenu = false }) {
                for (choice in LyricsSourceChoice.choices(serverMode)) {
                    val status = choice.statusKey?.let { lyrics.outcome?.tried?.get(it) }
                    DropdownMenuItem(text = {
                        Column {
                            Text(choice.menuLabel + if (choice == forced) "  ✓" else "")
                            if (choice == LyricsSourceChoice.Auto) Text(LyricsSourceChoice.autoHint(serverMode), style = MaterialTheme.typography.bodySmall)
                            else if (status != null) Text(if (status.name == "Ok") "Found" else "Nothing found", style = MaterialTheme.typography.bodySmall)
                        }
                    }, onClick = { model.setForced(choice); forced = choice; sourceMenu = false })
                }
            }
        }
        val outcome = lyrics.outcome
        when {
            lyrics.itemId != item.id || lyrics.loading -> LoadingBox()
            outcome?.result?.instrumental == true -> Message("Instrumental")
            outcome?.result == null || outcome.result!!.lines.isEmpty() -> Message(
                if (plugin == null && serverOnly) "No lyrics. Your server has no Cascade Server plugin; turn off Server-only lyrics in Settings to look elsewhere."
                else "No lyrics for this song.")
            else -> LyricsView(outcome.result!!, tuning, { engine.player.currentPosition }, playing, { engine.seekTo(it) })
        }
    }
}

@Composable
private fun Message(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.titleMedium)
    }
}

/**
 * The queue: tap to jump, the arrows to reorder, the cross to remove (never
 * the playing row). Up next is under the current track, history above it.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun QueueList() {
    val engine = appState.engine
    val state by engine.state.collectAsState()
    val items = state.queue.items
    val current = state.queue.index
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = current.coerceAtLeast(0))
    LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
        itemsIndexed(items, key = { i, it -> "$i:${it.id}" }) { i, t ->
            val playing = i == current
            Row(Modifier.fillMaxWidth().combinedClickable(onClick = { engine.jump(i) }).padding(vertical = 6.dp)
                .then(if (i < current) Modifier.background(Color.Transparent) else Modifier),
                verticalAlignment = Alignment.CenterVertically) {
                Artwork(t.artItemId, 40.dp)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(t.name ?: "", color = if (playing) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = if (i < current) 0.5f else 1f),
                        maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = if (playing) FontWeight.Bold else FontWeight.Normal)
                    Text(t.artistLine, color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.bodySmall, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                }
                if (!playing) {
                    IconButton(onClick = { engine.move(i, i - 1) }, enabled = i > 0) { Icon(Icons.Default.KeyboardArrowUp, "Move up", tint = Color.White.copy(alpha = 0.7f)) }
                    IconButton(onClick = { engine.move(i, i + 1) }, enabled = i < items.size - 1) { Icon(Icons.Default.KeyboardArrowDown, "Move down", tint = Color.White.copy(alpha = 0.7f)) }
                    IconButton(onClick = { engine.remove(i) }) { Icon(Icons.Default.Close, "Remove", tint = Color.White.copy(alpha = 0.7f)) }
                }
            }
            if (playing) HorizontalDivider(color = Color.White.copy(alpha = 0.15f))
        }
    }
}
