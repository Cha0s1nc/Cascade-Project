package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.android.BuildConfig
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.QuickConnect
import xyz.chaosinc.cascade.core.StreamingQuality
import xyz.chaosinc.cascade.core.authorizeQuickConnect
import xyz.chaosinc.cascade.core.views

@Composable
private fun SectionHeader(title: String) {
    Text(title, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 4.dp))
}

@Composable
fun SettingsScreen(onEditHeaders: () -> Unit) {
    val state = appState
    val session = state.session.collectAsState().value ?: return
    Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
        SectionHeader("Account")
        Text("${session.username ?: "Signed in"} on ${session.config.url}", Modifier.padding(horizontal = 16.dp))
        TextButton(onClick = { state.signOut() }, modifier = Modifier.padding(start = 8.dp)) { Text("Sign Out") }

        SectionHeader("Libraries")
        LibraryPicker()

        SectionHeader("Playback")
        QualityPicker("Streaming quality on Wi-Fi", StreamingQuality.WIFI_KEY)
        QualityPicker("Streaming quality on cellular", StreamingQuality.CELLULAR_KEY)
        Text("A cap below a file's own bitrate makes the server convert it to AAC at that rate.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))

        SectionHeader("Lyrics")
        val serverOnly by state.serverOnlyLyrics.collectAsState()
        val plugin by state.plugin.collectAsState()
        Row(Modifier.fillMaxWidth().clickable { state.setServerOnlyLyrics(!serverOnly) }.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Server-only lyrics")
                Text(if (plugin == null) "Your server has no Cascade Server plugin, so lyrics come from Kugou, LRCLIB and Jellyfin."
                    else "Only your server's Cascade plugin. Off adds Kugou, LRCLIB and Jellyfin's own lyrics.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(serverOnly, { state.setServerOnlyLyrics(it) })
        }

        SectionHeader("Quick Connect")
        ApproveQuickConnect()

        SectionHeader("Connection")
        TextButton(onClick = onEditHeaders, modifier = Modifier.padding(start = 8.dp)) {
            Text("Reverse proxy headers (${state.proxy.headers.size})")
        }

        SectionHeader("About")
        Text("Cascade for Android ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", Modifier.padding(horizontal = 16.dp),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Which music libraries to browse. None ticked means all of them. */
@Composable
private fun LibraryPicker() {
    val state = appState
    val session = state.session.collectAsState().value ?: return
    var libraries by remember { mutableStateOf<List<JfItem>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(session.client) {
        runCatching { withContext(Dispatchers.IO) { session.client.views().filter { it.collectionType == "music" } } }
            .onSuccess { libraries = it }.onFailure { error = it.message }
    }
    val chosen = session.config.libraryIds
    error?.let { ErrorText(it) }
    val all = libraries ?: run { LoadingBox(); return }
    if (all.isEmpty()) { Text("This account has no music libraries.", Modifier.padding(horizontal = 16.dp)); return }
    Text(if (chosen.isEmpty()) "Browsing every music library." else "Browsing ${chosen.size} of ${all.size}.",
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp))
    for (lib in all) {
        val on = lib.id in chosen
        Row(Modifier.fillMaxWidth().clickable {
            // Kept in the server's order, so merged lists follow it.
            val next = if (on) chosen - lib.id else all.map { it.id }.filter { it in chosen || it == lib.id }
            state.setLibraries(next)
        }.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Checkbox(on, null)
            Text(lib.name ?: "")
        }
    }
}

@Composable
private fun QualityPicker(title: String, key: String) {
    val settings = appState.settings
    var value by remember { mutableStateOf(StreamingQuality.fromStored(settings.raw(key))) }
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Text(value.label, color = MaterialTheme.colorScheme.primary)
        DropdownMenu(open, { open = false }) {
            for (q in StreamingQuality.entries) DropdownMenuItem(text = { Text(q.label) }, onClick = {
                value = q; settings.putInt(key, q.raw); open = false
            })
        }
    }
}

/** Sign another device in as this account by entering the code it shows. */
@Composable
private fun ApproveQuickConnect() {
    val client = currentClient() ?: return
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(code, { code = it; message = null }, label = { Text("Code from the other device") }, singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
        val normalized = QuickConnect.normalizedCode(code)
        OutlinedButton(enabled = normalized != null && !busy, onClick = {
            busy = true
            scope.launch {
                message = runCatching { withContext(Dispatchers.IO) { client.authorizeQuickConnect(normalized!!) } }
                    .fold({ "Approved. The other device is signing in." }, { it.message ?: "Not approved" })
                busy = false
            }
        }) { Text("Approve") }
        message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
