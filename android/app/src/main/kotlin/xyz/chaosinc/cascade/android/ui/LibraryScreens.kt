package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.core.AlbumSortField
import xyz.chaosinc.cascade.core.ArtistSortField
import xyz.chaosinc.cascade.core.BrowseFilter
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.LibraryPrefs
import xyz.chaosinc.cascade.core.PlaylistSortField
import xyz.chaosinc.cascade.core.SongSortField
import xyz.chaosinc.cascade.core.SortDirection
import xyz.chaosinc.cascade.core.albums
import xyz.chaosinc.cascade.core.artists
import xyz.chaosinc.cascade.core.defaultDirection
import xyz.chaosinc.cascade.core.frequentlyPlayed
import xyz.chaosinc.cascade.core.genres
import xyz.chaosinc.cascade.core.label
import xyz.chaosinc.cascade.core.playlists
import xyz.chaosinc.cascade.core.randomSongs
import xyz.chaosinc.cascade.core.recentlyAdded
import xyz.chaosinc.cascade.core.recentlyPlayed
import xyz.chaosinc.cascade.core.recentlyPlayedAlbums
import xyz.chaosinc.cascade.core.serverSortBy
import xyz.chaosinc.cascade.core.songs
import xyz.chaosinc.cascade.core.years

/** Where a screen can send the person: the tab's own navigation, set by MainScreen. */
class Nav(
    val album: (String) -> Unit,
    val artist: (String) -> Unit,
    val playlist: (String) -> Unit,
    val genre: (String, String) -> Unit,
    val genres: () -> Unit,
) {
    val trackActions = TrackActions(openAlbum = album, openArtist = artist)
}

/** The tab bar sits under these lists, and the mini player above it. */
val listPadding = PaddingValues(bottom = 16.dp)

/** A session-scoped key part, so a list reloads when the libraries or account change. */
@Composable
private fun sessionKey(): Any? {
    val session = appState.session.collectAsState().value ?: return null
    return session.config.userId to session.config.libraryIds
}

@Composable
fun HomeScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    val recent: ListModel = viewModel(key = "home.recent")
    val added: ListModel = viewModel(key = "home.added")
    val frequent: ListModel = viewModel(key = "home.frequent")
    LaunchedEffect(key) {
        recent.bind(key to "recent", null) { _, _ -> client.recentlyPlayed(24) }
        added.bind(key to "added", null) { _, _ -> client.recentlyAdded(24) }
        frequent.bind(key to "frequent", null) { _, _ -> client.frequentlyPlayed(20) }
    }
    val engine = appState.engine
    LazyColumn(contentPadding = listPadding) {
        item { AlbumShelf("Recently Added", added, nav) }
        item { TrackShelf("Recently Played", recent) { i -> engine.play(recent.items, i) } }
        item { TrackShelf("Most Played", frequent) { i -> engine.play(frequent.items, i) } }
        if (recent.items.isEmpty() && added.items.isEmpty() && !recent.loading && !added.loading) {
            item { recent.error?.let { ErrorText(it) } ?: Text("Nothing here yet. Play something and it shows up.", Modifier.padding(16.dp)) }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 8.dp))
}

@Composable
private fun AlbumShelf(title: String, model: ListModel, nav: Nav) {
    if (model.items.isEmpty()) { if (model.loading) LoadingBox(); return }
    SectionTitle(title)
    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(model.items, key = { it.id }) { ItemTile(it, 140.dp, onClick = { nav.album(it.id) }) }
    }
}

@Composable
private fun TrackShelf(title: String, model: ListModel, play: (Int) -> Unit) {
    if (model.items.isEmpty()) return
    SectionTitle(title)
    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        itemsIndexed(model.items, key = { _, it -> it.id }) { i, item ->
            ItemTile(item, 120.dp, onClick = { play(i) }, subtitle = item.artistLine)
        }
    }
}

/** Sort and filter controls shared by the browsing screens: a sort menu with direction, and a filter menu. */
@Composable
fun <F> SortFilterBar(
    fields: List<F>, label: (F) -> String, current: F, direction: SortDirection,
    onSort: (F, SortDirection) -> Unit, defaultDirection: (F) -> SortDirection,
    filter: BrowseFilter?, onFilter: ((BrowseFilter) -> Unit)?, decades: List<Int> = emptyList(),
    leading: @Composable () -> Unit = {},
) {
    var sortOpen by remember { mutableStateOf(false) }
    var filterOpen by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        leading()
        Spacer(Modifier.weight(1f))
        if (filter != null && onFilter != null) {
            Box {
                IconButton(onClick = { filterOpen = true }) {
                    Icon(Icons.Default.FilterList, "Filter", tint = if (filter.isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                }
                DropdownMenu(filterOpen, { filterOpen = false }) {
                    DropdownMenuItem(text = { Text("Favorites only") }, leadingIcon = { Checkbox(filter.favoritesOnly, null) },
                        onClick = { onFilter(filter.copy(favoritesOnly = !filter.favoritesOnly)) })
                    HorizontalDivider()
                    for (p in BrowseFilter.Played.entries) {
                        DropdownMenuItem(text = { Text(when (p) { BrowseFilter.Played.Any -> "Played or not"; BrowseFilter.Played.Played -> "Played"; BrowseFilter.Played.Unplayed -> "Never played" }) },
                            leadingIcon = { Checkbox(filter.played == p, null) }, onClick = { onFilter(filter.copy(played = p)) })
                    }
                    if (decades.isNotEmpty()) {
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("Any decade") }, leadingIcon = { Checkbox(filter.decade == null, null) },
                            onClick = { onFilter(filter.copy(decade = null)) })
                        for (d in decades) DropdownMenuItem(text = { Text("${d}s") }, leadingIcon = { Checkbox(filter.decade == d, null) },
                            onClick = { onFilter(filter.copy(decade = d)) })
                    }
                    if (filter.isActive) {
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("Clear filters") }, onClick = { onFilter(BrowseFilter()); filterOpen = false })
                    }
                }
            }
        }
        Box {
            IconButton(onClick = { sortOpen = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort") }
            DropdownMenu(sortOpen, { sortOpen = false }) {
                for (f in fields) {
                    DropdownMenuItem(
                        text = { Text(label(f) + if (f == current) (if (direction == SortDirection.Descending) "  ↓" else "  ↑") else "") },
                        onClick = {
                            // Picking the current field flips it; a new one starts in its natural direction.
                            onSort(f, if (f == current) direction.flipped else defaultDirection(f))
                            sortOpen = false
                        })
                }
            }
        }
    }
}

@Composable
private fun PagedGrid(model: ListModel, header: @Composable () -> Unit, tile: @Composable (JfItem) -> Unit) {
    LazyVerticalGrid(GridCells.Adaptive(150.dp), contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item(span = { GridItemSpan(maxLineSpan) }) { header() }
        itemsIndexed(model.items, key = { _, it -> it.id }) { i, item ->
            if (i >= model.items.size - 20) LaunchedEffect(model.items.size) { model.loadMore() }
            tile(item)
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column {
                if (model.loading) LoadingBox()
                model.error?.let { ErrorText(it) }
                if (!model.loading && model.error == null && model.items.isEmpty()) Text("Nothing here.", Modifier.padding(16.dp))
            }
        }
    }
}

private fun loadPrefs(key: String) = LibraryPrefs.fromStored(appState.settings.string(key)) ?: LibraryPrefs()

@Composable
fun AlbumsScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    var prefs by remember { mutableStateOf(loadPrefs(LibraryPrefs.ALBUMS_KEY)) }
    var decades by remember { mutableStateOf(emptyList<Int>()) }
    LaunchedEffect(key) { decades = runCatching { withContext(Dispatchers.IO) { BrowseFilter.decades(client.years("MusicAlbum")) } }.getOrDefault(emptyList()) }
    val field = AlbumSortField.of(prefs.field)
    val model: ListModel = viewModel(key = "albums")
    LaunchedEffect(key, prefs) {
        val sortBy = field.serverSortBy
        if (sortBy == null) {
            // Jellyfin keeps no album play date: this order comes from the tracks, in one go.
            model.bind(Triple(key, prefs, "played"), null) { _, _ -> client.recentlyPlayedAlbums(filter = prefs.filter) }
        } else {
            model.bind(Triple(key, prefs, "paged"), ListModel.PAGE) { start, limit ->
                client.albums(limit ?: 500, start, sortBy, prefs.direction.serverValue, filter = prefs.filter)
            }
        }
    }
    fun save(p: LibraryPrefs) { prefs = p; appState.settings.putString(LibraryPrefs.ALBUMS_KEY, p.stored) }
    PagedGrid(model, header = {
        SortFilterBar(AlbumSortField.entries, { it.label }, field, prefs.direction, { f, d -> save(prefs.copy(field = f.raw, direction = d)) },
            { it.defaultDirection }, prefs.filter, { save(prefs.copy(filter = it)) }, decades) {
            FilledTonalButton(onClick = nav.genres) { Text("Genres") }
        }
    }) { ItemTile(it, 160.dp, onClick = { nav.album(it.id) }) }
}

@Composable
fun ArtistsScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    var prefs by remember { mutableStateOf(loadPrefs(LibraryPrefs.ARTISTS_KEY)) }
    val field = ArtistSortField.of(prefs.field)
    val model: ListModel = viewModel(key = "artists")
    LaunchedEffect(key, prefs) {
        // Jellyfin filters artists by the artist's own genre metadata, which is
        // empty, so artists have no genre filter, as on the desktop.
        model.bind(key to prefs, ListModel.PAGE) { start, limit ->
            client.artists(limit ?: 500, start, field.serverSortBy, prefs.direction.serverValue, prefs.filter.copy(genre = null, decade = null))
        }
    }
    fun save(p: LibraryPrefs) { prefs = p; appState.settings.putString(LibraryPrefs.ARTISTS_KEY, p.stored) }
    PagedGrid(model, header = {
        SortFilterBar(ArtistSortField.entries, { it.label }, field, prefs.direction, { f, d -> save(prefs.copy(field = f.raw, direction = d)) },
            { it.defaultDirection }, prefs.filter, { save(prefs.copy(filter = it)) })
    }) { ItemTile(it, 160.dp, onClick = { nav.artist(it.id) }, subtitle = "", round = true) }
}

@Composable
fun SongsScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    val settings = appState.settings
    var field by remember { mutableStateOf(SongSortField.of(settings.string(LibraryPrefs.SONGS_SORT_FIELD_KEY))) }
    var direction by remember { mutableStateOf(if (settings.string(LibraryPrefs.SONGS_SORT_DIR_KEY) == "desc") SortDirection.Descending else SortDirection.Ascending) }
    var filter by remember { mutableStateOf(BrowseFilter.fromRaw(settings.string(LibraryPrefs.SONGS_FILTER_KEY)) ?: BrowseFilter()) }
    var decades by remember { mutableStateOf(emptyList<Int>()) }
    LaunchedEffect(key) { decades = runCatching { withContext(Dispatchers.IO) { BrowseFilter.decades(client.years("Audio")) } }.getOrDefault(emptyList()) }
    val model: ListModel = viewModel(key = "songs")
    LaunchedEffect(key, field, direction, filter) {
        model.bind(listOf(key, field, direction, filter), ListModel.PAGE) { start, limit ->
            client.songs(limit, start, field.serverSortBy, direction.serverValue, filter = filter)
        }
    }
    val engine = appState.engine
    val scope = rememberCoroutineScope()
    val playing = engine.state.collectAsState().value.current?.id
    var busy by remember { mutableStateOf(false) }
    LazyColumn(contentPadding = listPadding) {
        item {
            SortFilterBar(SongSortField.entries, { it.label }, field, direction, { f, d ->
                field = f; direction = d
                settings.putString(LibraryPrefs.SONGS_SORT_FIELD_KEY, f.raw)
                settings.putString(LibraryPrefs.SONGS_SORT_DIR_KEY, if (d == SortDirection.Descending) "desc" else "asc")
            }, { it.defaultDirection }, filter, { filter = it; settings.putString(LibraryPrefs.SONGS_FILTER_KEY, it.rawValue) }, decades) {
                // Play All is the whole library in this order, fetched once;
                // Shuffle is a random thousand, so it starts at once.
                Button(enabled = !busy, onClick = {
                    busy = true
                    scope.launch {
                        val all = runCatching { withContext(Dispatchers.IO) { client.songs(null, 0, field.serverSortBy, direction.serverValue, filter = filter) } }.getOrNull()
                        if (!all.isNullOrEmpty()) engine.play(all)
                        busy = false
                    }
                }) { Icon(Icons.Default.PlayArrow, null); Text("Play All") }
                Spacer(Modifier.width(8.dp))
                FilledTonalButton(enabled = !busy, onClick = {
                    busy = true
                    scope.launch {
                        val random = runCatching { withContext(Dispatchers.IO) { client.randomSongs(filter = filter) } }.getOrNull()
                        if (!random.isNullOrEmpty()) engine.play(random)
                        busy = false
                    }
                }) { Icon(Icons.Default.Shuffle, null); Text("Shuffle") }
            }
        }
        itemsIndexed(model.items, key = { _, it -> it.id }) { i, track ->
            if (i >= model.items.size - 30) LaunchedEffect(model.items.size) { model.loadMore() }
            // Tapping a song plays the list loaded so far from it, as the iPhone does.
            TrackRow(track, onClick = { engine.play(model.items, i) }, actions = nav.trackActions, playing = track.id == playing)
        }
        item {
            if (model.loading) LoadingBox()
            model.error?.let { ErrorText(it) }
        }
    }
}

@Composable
fun PlaylistsScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    var prefs by remember { mutableStateOf(loadPrefs(LibraryPrefs.PLAYLISTS_KEY)) }
    val field = PlaylistSortField.of(prefs.field)
    val model: ListModel = viewModel(key = "playlists")
    LaunchedEffect(key, prefs) {
        model.bind(key to prefs, null) { _, _ -> client.playlists(field.serverSortBy, prefs.direction.serverValue) }
    }
    fun save(p: LibraryPrefs) { prefs = p; appState.settings.putString(LibraryPrefs.PLAYLISTS_KEY, p.stored) }
    LazyColumn(contentPadding = listPadding) {
        item {
            SortFilterBar(PlaylistSortField.entries, { it.label }, field, prefs.direction, { f, d -> save(prefs.copy(field = f.raw, direction = d)) },
                { it.defaultDirection }, null, null)
        }
        items(model.items, key = { it.id }) { p ->
            Row(Modifier.fillMaxWidth().clickable { nav.playlist(p.id) }.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Artwork(p.id, 56.dp)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(p.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis)
                    p.childCount?.let { Text(if (it == 1) "1 song" else "$it songs", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
        }
        item {
            if (model.loading) LoadingBox()
            model.error?.let { ErrorText(it) }
            if (!model.loading && model.error == null && model.items.isEmpty()) Text("No playlists yet.", Modifier.padding(16.dp))
        }
    }
}

@Composable
fun GenresScreen(nav: Nav) {
    val client = currentClient() ?: return
    val key = sessionKey()
    val model: ListModel = viewModel(key = "genres")
    LaunchedEffect(key) { model.bind(key ?: "genres", null) { _, _ -> client.genres() } }
    LazyColumn(contentPadding = listPadding) {
        items(model.items, key = { it.id }) { g ->
            Text(g.name ?: "", Modifier.fillMaxWidth().clickable { nav.genre(g.id, g.name ?: "") }.padding(horizontal = 16.dp, vertical = 14.dp))
        }
        item {
            if (model.loading) LoadingBox()
            model.error?.let { ErrorText(it) }
        }
    }
}
