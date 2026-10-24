package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.core.ArtistPage
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.albumsByArtist
import xyz.chaosinc.cascade.core.albumsInGenre
import xyz.chaosinc.cascade.core.item
import xyz.chaosinc.cascade.core.similarArtists
import xyz.chaosinc.cascade.core.songsInGenre
import xyz.chaosinc.cascade.core.tracksByArtist
import xyz.chaosinc.cascade.core.tracksInAlbum
import xyz.chaosinc.cascade.core.tracksInPlaylist

/** The item a detail page is about, fetched by id (a row only carries part of it). */
@Composable
private fun rememberItem(id: String): Pair<JfItem?, String?> {
    val client = currentClient()
    var item by remember(id) { mutableStateOf<JfItem?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id, client) {
        if (client == null) return@LaunchedEffect
        runCatching { withContext(Dispatchers.IO) { client.item(id) } }
            .onSuccess { item = it }.onFailure { error = it.message }
    }
    return item to error
}

@Composable
private fun PlayShuffleRow(tracks: List<JfItem>) {
    val engine = appState.engine
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(onClick = { engine.play(tracks) }, enabled = tracks.isNotEmpty(), modifier = Modifier.weight(1f)) {
            Icon(Icons.Default.PlayArrow, null); Text("Play")
        }
        FilledTonalButton(onClick = { engine.play(tracks, (tracks.indices).random(), shuffle = true) }, enabled = tracks.isNotEmpty(),
            modifier = Modifier.weight(1f)) { Icon(Icons.Default.Shuffle, null); Text("Shuffle") }
    }
}

@Composable
private fun Header(artId: String, title: String, subtitle: String?, detail: String?, round: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Artwork(artId, 240.dp, corner = if (round) 120.dp else 12.dp)
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        if (!subtitle.isNullOrEmpty()) Text(subtitle, color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center)
        if (!detail.isNullOrEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun songsLine(tracks: List<JfItem>): String {
    val total = tracks.sumOf { it.durationSeconds }
    val count = if (tracks.size == 1) "1 song" else "${tracks.size} songs"
    return "$count · ${formatDuration(total)}"
}

@Composable
fun AlbumScreen(id: String, nav: Nav) {
    val client = currentClient() ?: return
    val (album, error) = rememberItem(id)
    val tracks: ListModel = viewModel(key = "album.$id")
    LaunchedEffect(id) { tracks.bind(id, null) { _, _ -> client.tracksInAlbum(id) } }
    val engine = appState.engine
    val playing = engine.state.collectAsState().value.current?.id
    // A disc heading only when the album has more than one disc.
    val discs = tracks.items.mapNotNull { it.parentIndexNumber }.distinct()
    LazyColumn(contentPadding = listPadding) {
        item {
            Header(id, album?.name ?: "", album?.albumArtist,
                listOfNotNull(album?.productionYear?.toString(), tracks.items.takeIf { it.isNotEmpty() }?.let(::songsLine)).joinToString(" · "))
            val artistId = album?.albumArtists?.firstOrNull()?.id
            if (artistId != null) TextButton(onClick = { nav.artist(artistId) }, modifier = Modifier.padding(start = 8.dp)) { Text("Go to Artist") }
            PlayShuffleRow(tracks.items)
            error?.let { ErrorText(it) }
        }
        itemsIndexed(tracks.items, key = { _, it -> it.id }) { i, t ->
            if (discs.size > 1 && (i == 0 || tracks.items[i - 1].parentIndexNumber != t.parentIndexNumber)) {
                Text("Disc ${t.parentIndexNumber ?: 1}", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 16.dp, top = 12.dp))
            }
            TrackRow(t, onClick = { engine.play(tracks.items, i) }, actions = TrackActions(openArtist = nav.artist), showArt = false,
                number = t.indexNumber, playing = t.id == playing)
        }
        item { if (tracks.loading) LoadingBox(); tracks.error?.let { ErrorText(it) } }
    }
}

@Composable
fun ArtistScreen(id: String, nav: Nav) {
    val client = currentClient() ?: return
    val (artist, error) = rememberItem(id)
    val albums: ListModel = viewModel(key = "artist.albums.$id")
    val songs: ListModel = viewModel(key = "artist.songs.$id")
    val similar: ListModel = viewModel(key = "artist.similar.$id")
    LaunchedEffect(id) {
        albums.bind(id, null) { _, _ -> client.albumsByArtist(id) }
        songs.bind(id, null) { _, _ -> client.tracksByArtist(id) }
        similar.bind(id, null) { _, _ -> runCatching { client.similarArtists(id) }.getOrDefault(emptyList()) }
    }
    val engine = appState.engine
    val top = remember(songs.items) { ArtistPage.topSongs(songs.items) }
    var bioOpen by remember { mutableStateOf(false) }
    LazyColumn(contentPadding = listPadding) {
        item {
            Header(id, artist?.name ?: "", null, songs.items.takeIf { it.isNotEmpty() }?.let { songsLine(it) }, round = true)
            PlayShuffleRow(songs.items)
            error?.let { ErrorText(it) }
            artist?.overview?.takeIf { it.isNotBlank() }?.let { bio ->
                Text(bio, maxLines = if (bioOpen) Int.MAX_VALUE else 3, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                TextButton(onClick = { bioOpen = !bioOpen }, modifier = Modifier.padding(start = 8.dp)) { Text(if (bioOpen) "Less" else "More") }
            }
        }
        if (top.isNotEmpty()) {
            item { Text("Top Songs", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(16.dp)) }
            itemsIndexed(top, key = { _, it -> "top" + it.id }) { i, t -> TrackRow(t, { engine.play(top, i) }, TrackActions(openAlbum = nav.album)) }
        }
        if (albums.items.isNotEmpty()) {
            item {
                Text("Albums", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(16.dp))
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(albums.items, key = { it.id }) { ItemTile(it, 150.dp, onClick = { nav.album(it.id) }, subtitle = it.productionYear?.toString() ?: "") }
                }
            }
        }
        if (similar.items.isNotEmpty()) {
            item {
                Text("Similar Artists", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(16.dp))
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(similar.items, key = { it.id }) { ItemTile(it, 120.dp, onClick = { nav.artist(it.id) }, subtitle = "", round = true) }
                }
            }
        }
        item { if (albums.loading || songs.loading) LoadingBox() }
    }
}

@Composable
fun PlaylistScreen(id: String, nav: Nav) {
    val client = currentClient() ?: return
    val (playlist, error) = rememberItem(id)
    val tracks: ListModel = viewModel(key = "playlist.$id")
    LaunchedEffect(id) { tracks.bind(id, null) { _, _ -> client.tracksInPlaylist(id) } }
    val engine = appState.engine
    val playing = engine.state.collectAsState().value.current?.id
    LazyColumn(contentPadding = listPadding) {
        item {
            Header(id, playlist?.name ?: "", null, tracks.items.takeIf { it.isNotEmpty() }?.let(::songsLine))
            PlayShuffleRow(tracks.items)
            error?.let { ErrorText(it) }
        }
        itemsIndexed(tracks.items, key = { i, it -> "$i:${it.id}" }) { i, t ->
            TrackRow(t, { engine.play(tracks.items, i) }, nav.trackActions, playing = t.id == playing)
        }
        item { if (tracks.loading) LoadingBox(); tracks.error?.let { ErrorText(it) } }
    }
}

@Composable
fun GenreScreen(id: String, name: String, nav: Nav) {
    val client = currentClient() ?: return
    val albums: ListModel = viewModel(key = "genre.$id")
    LaunchedEffect(id) { albums.bind(id, null) { _, _ -> client.albumsInGenre(id) } }
    var songs by remember(id) { mutableStateOf<List<JfItem>>(emptyList()) }
    LaunchedEffect(id) { songs = runCatching { withContext(Dispatchers.IO) { client.songsInGenre(id) } }.getOrDefault(emptyList()) }
    LazyColumn(contentPadding = listPadding) {
        item {
            Text(name, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(16.dp))
            PlayShuffleRow(songs)
        }
        items(albums.items.chunked(2), key = { it.first().id }) { pair ->
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                for (a in pair) ItemTile(a, 160.dp, onClick = { nav.album(a.id) })
                if (pair.size == 1) Spacer(Modifier.width(160.dp))
            }
        }
        item { if (albums.loading) LoadingBox(); albums.error?.let { ErrorText(it) } }
    }
}
