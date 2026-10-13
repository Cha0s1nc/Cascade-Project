package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.core.SearchResults
import xyz.chaosinc.cascade.core.searchEverything

/** Songs, albums and artists, each with its own cap, as the desktop's search does. Debounced as it is typed. */
@Composable
fun SearchScreen(nav: Nav) {
    val client = currentClient() ?: return
    var term by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf(SearchResults()) }
    var searching by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { if (term.isEmpty()) runCatching { focus.requestFocus() } }
    LaunchedEffect(term) {
        if (term.isBlank()) { results = SearchResults(); return@LaunchedEffect }
        delay(300)
        searching = true
        error = null
        runCatching { withContext(Dispatchers.IO) { client.searchEverything(term) } }
            .onSuccess { results = it }.onFailure { error = it.message }
        searching = false
    }
    val engine = appState.engine
    LazyColumn(contentPadding = listPadding) {
        item {
            OutlinedTextField(term, { term = it }, leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text("Songs, albums, artists") },
                singleLine = true, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth().padding(16.dp).focusRequester(focus))
        }
        if (results.artists.isNotEmpty()) item {
            Text("Artists", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(16.dp))
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(results.artists, key = { it.id }) { ItemTile(it, 110.dp, onClick = { nav.artist(it.id) }, subtitle = "", round = true) }
            }
        }
        if (results.albums.isNotEmpty()) item {
            Text("Albums", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(16.dp))
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                items(results.albums, key = { it.id }) { ItemTile(it, 140.dp, onClick = { nav.album(it.id) }) }
            }
        }
        if (results.songs.isNotEmpty()) {
            item { Text("Songs", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(16.dp)) }
            itemsIndexed(results.songs, key = { _, it -> it.id }) { i, t -> TrackRow(t, { engine.play(results.songs, i) }, nav.trackActions) }
        }
        item {
            if (searching) LoadingBox()
            error?.let { ErrorText(it) }
            if (!searching && error == null && term.isNotBlank() && results.isEmpty) Text("No results for “$term”.", Modifier.padding(16.dp))
        }
    }
}
