package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil3.compose.SubcomposeAsyncImage
import coil3.request.ImageRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.android.CascadeApp
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.setFavorite

/** The signed-in client, or null while signed out. */
@Composable
fun currentClient() = CascadeApp.state.session.collectAsState().value?.client

/**
 * An item's Primary image, sized for where it is drawn. Cached by item and
 * size, not by URL: the URL carries the token, which changes at every sign-in.
 */
@Composable
fun Artwork(itemId: String?, size: Dp, modifier: Modifier = Modifier, corner: Dp = 6.dp) {
    val client = currentClient()
    val px = with(LocalDensity.current) { size.roundToPx() }.coerceAtMost(1200)
    // Requested at a few fixed sizes so one download serves similar views.
    val bucket = listOf(96, 192, 384, 768, 1200).firstOrNull { it >= px } ?: 1200
    val shape = RoundedCornerShape(corner)
    Box(modifier.size(size).clip(shape).background(MaterialTheme.colorScheme.surfaceVariant), contentAlignment = Alignment.Center) {
        if (client != null && itemId != null) {
            val context = LocalContext.current
            val request = remember(itemId, bucket, client) {
                ImageRequest.Builder(context)
                    .data(client.imageUrl(itemId, bucket))
                    .memoryCacheKey("$itemId@$bucket")
                    .diskCacheKey("$itemId@$bucket")
                    .build()
            }
            SubcomposeAsyncImage(
                model = request,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
                error = { Placeholder(size) },
                loading = { Placeholder(size) },
            )
        } else Placeholder(size)
    }
}

@Composable
private fun Placeholder(size: Dp) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Icon(Icons.Default.MusicNote, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
            modifier = Modifier.size(size / 2.5f))
    }
}

@Composable
fun LoadingBox(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

/** Shown, never swallowed: a screen that fails quietly is indistinguishable from an empty library. */
@Composable
fun ErrorText(message: String, modifier: Modifier = Modifier) {
    Text(message, color = MaterialTheme.colorScheme.error, modifier = modifier.padding(16.dp))
}

fun formatDuration(seconds: Double): String {
    if (!seconds.isFinite() || seconds < 0) return "0:00"
    val s = seconds.toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** What a track row's menu may do; Go to entries hide where there is nowhere to go. */
class TrackActions(
    val openAlbum: ((String) -> Unit)? = null,
    val openArtist: ((String) -> Unit)? = null,
)

/**
 * A track's long-press actions, the same everywhere a track is listed, in the
 * iPhone's groups: queue actions, then favorite, then going to its album or
 * artist.
 */
@Composable
fun TrackMenu(track: JfItem, expanded: Boolean, onDismiss: () -> Unit, actions: TrackActions) {
    val engine = CascadeApp.state.engine
    val client = currentClient()
    val scope = rememberCoroutineScope()
    var favorite by remember(track.id) { mutableStateOf(track.isFavorite) }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Play Next") }, onClick = { engine.playNext(listOf(track)); onDismiss() })
        DropdownMenuItem(text = { Text("Add to Queue") }, onClick = { engine.addToQueue(listOf(track)); onDismiss() })
        DropdownMenuItem(text = { Text("Instant Mix") }, onClick = { engine.instantMix(track); onDismiss() })
        HorizontalDivider()
        DropdownMenuItem(text = { Text(if (favorite) "Unfavorite" else "Favorite") }, onClick = {
            val want = !favorite
            onDismiss()
            scope.launch {
                // Shown as changed only once the server took it.
                val ok = runCatching { withContext(Dispatchers.IO) { client?.setFavorite(want, track.id) } }.isSuccess
                if (ok) favorite = want
            }
        })
        val albumId = track.albumId
        val artistId = track.artistItems?.firstOrNull()?.id ?: track.albumArtists?.firstOrNull()?.id
        if ((albumId != null && actions.openAlbum != null) || (artistId != null && actions.openArtist != null)) HorizontalDivider()
        if (albumId != null && actions.openAlbum != null) {
            DropdownMenuItem(text = { Text("Go to Album") }, onClick = { onDismiss(); actions.openAlbum.invoke(albumId) })
        }
        if (artistId != null && actions.openArtist != null) {
            DropdownMenuItem(text = { Text("Go to Artist") }, onClick = { onDismiss(); actions.openArtist.invoke(artistId) })
        }
    }
}

/**
 * One track in a list: art (or its number on an album page), title, artist,
 * length. Tap plays from here; long-press or the menu button opens TrackMenu.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TrackRow(
    track: JfItem,
    onClick: () -> Unit,
    actions: TrackActions,
    showArt: Boolean = true,
    number: Int? = null,
    playing: Boolean = false,
) {
    var menu by remember { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = { menu = true })
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showArt) Artwork(track.artItemId, 44.dp)
        else Text(number?.toString() ?: "", modifier = Modifier.width(28.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(track.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (playing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                fontWeight = if (playing) FontWeight.SemiBold else FontWeight.Normal)
            val artist = track.artistLine
            if (artist.isNotEmpty()) Text(artist, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (track.isFavorite) Icon(Icons.Default.Favorite, "Favorite", Modifier.size(14.dp).padding(end = 2.dp), tint = MaterialTheme.colorScheme.primary)
        Text(formatDuration(track.durationSeconds), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, "More") }
            TrackMenu(track, menu, { menu = false }, actions)
        }
    }
}

/** A square tile for an album, artist or playlist in a grid or shelf. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ItemTile(item: JfItem, size: Dp, onClick: () -> Unit, subtitle: String? = null, onLongClick: (() -> Unit)? = null, round: Boolean = false) {
    Column(Modifier.width(size).combinedClickable(onClick = onClick, onLongClick = onLongClick), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Artwork(item.artItemId, size, corner = if (round) size / 2 else 8.dp)
        Text(item.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
        val sub = subtitle ?: item.albumArtist ?: item.artists?.firstOrNull()
        if (!sub.isNullOrEmpty()) Text(sub, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The signed-in app's context for library loads, kept here so screens stay short. */
val appState get() = CascadeApp.state
