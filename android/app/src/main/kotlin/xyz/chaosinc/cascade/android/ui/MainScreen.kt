package xyz.chaosinc.cascade.android.ui

import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController

/** Signed in or not decides everything else. */
@Composable
fun CascadeRoot() {
    val session by appState.session.collectAsState()
    if (session == null) SignInScreen() else MainScreen()
}

private data class Tab(val route: String, val label: String, val icon: ImageVector)

// The iPhone's tabs. Search and Settings sit in the top bar: Android's bar
// holds five.
private val tabs = listOf(
    Tab("home", "Home", Icons.Default.Home),
    Tab("albums", "Albums", Icons.Default.Album),
    Tab("artists", "Artists", Icons.Default.Person),
    Tab("songs", "Songs", Icons.Default.MusicNote),
    Tab("playlists", "Playlists", Icons.AutoMirrored.Filled.QueueMusic),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen() {
    val navController = rememberNavController()
    val entry by navController.currentBackStackEntryAsState()
    val route = entry?.destination?.route ?: "home"
    var nowPlayingOpen by rememberSaveable { mutableStateOf(false) }
    val nav = Nav(
        album = { navController.navigate("album/$it") },
        artist = { navController.navigate("artist/$it") },
        playlist = { navController.navigate("playlist/$it") },
        genre = { id, name -> navController.navigate("genre/$id/${Uri.encode(name)}") },
        genres = { navController.navigate("genres") },
    )
    val isTab = tabs.any { it.route == route }
    Box(Modifier.fillMaxSize()) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(titleFor(route)) },
                    navigationIcon = {
                        if (!isTab) IconButton(onClick = { navController.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
                    },
                    actions = {
                        IconButton(onClick = { navController.navigate("search") { launchSingleTop = true } }) { Icon(Icons.Default.Search, "Search") }
                        IconButton(onClick = { navController.navigate("settings") { launchSingleTop = true } }) { Icon(Icons.Default.Settings, "Settings") }
                    },
                )
            },
            bottomBar = {
                Column {
                    MiniPlayer(onOpen = { nowPlayingOpen = true })
                    NavigationBar {
                        for (tab in tabs) {
                            NavigationBarItem(
                                selected = entry?.destination?.route == tab.route,
                                onClick = {
                                    navController.navigate(tab.route) {
                                        popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                        launchSingleTop = true
                                        restoreState = true
                                    }
                                },
                                icon = { Icon(tab.icon, null) },
                                label = { Text(tab.label) },
                            )
                        }
                    }
                }
            },
        ) { padding ->
            NavHost(navController, startDestination = "home", modifier = Modifier.padding(padding)) {
                composable("home") { HomeScreen(nav) }
                composable("albums") { AlbumsScreen(nav) }
                composable("artists") { ArtistsScreen(nav) }
                composable("songs") { SongsScreen(nav) }
                composable("playlists") { PlaylistsScreen(nav) }
                composable("genres") { GenresScreen(nav) }
                composable("search") { SearchScreen(nav) }
                composable("settings") { SettingsScreen(onEditHeaders = { navController.navigate("headers") }) }
                composable("headers") { ProxyHeadersEditor(onDone = { navController.popBackStack() }) }
                composable("album/{id}") { AlbumScreen(it.arguments?.getString("id") ?: return@composable, nav) }
                composable("artist/{id}") { ArtistScreen(it.arguments?.getString("id") ?: return@composable, nav) }
                composable("playlist/{id}") { PlaylistScreen(it.arguments?.getString("id") ?: return@composable, nav) }
                composable("genre/{id}/{name}") {
                    GenreScreen(it.arguments?.getString("id") ?: return@composable, it.arguments?.getString("name") ?: "", nav)
                }
            }
        }
        AnimatedVisibility(nowPlayingOpen, enter = slideInVertically { it }, exit = slideOutVertically { it }) {
            NowPlayingScreen(nav, onClose = { nowPlayingOpen = false })
        }
    }
}

private fun titleFor(route: String): String = when {
    route == "home" -> "Home"
    route == "albums" -> "Albums"
    route == "artists" -> "Artists"
    route == "songs" -> "Songs"
    route == "playlists" -> "Playlists"
    route == "genres" -> "Genres"
    route == "search" -> "Search"
    route == "settings" -> "Settings"
    route == "headers" -> "Proxy Headers"
    else -> ""
}

