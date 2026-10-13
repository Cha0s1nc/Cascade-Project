package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.android.data.Settings
import xyz.chaosinc.cascade.core.QuickConnect
import xyz.chaosinc.cascade.core.ServerMessage

/**
 * Sign in by password or Quick Connect, with proxy headers before anything is
 * sent (a proxy that wants one refuses the sign-in itself without it) and the
 * server's login disclaimer under the form, as Jellyfin's own page shows it.
 */
@Composable
fun SignInScreen() {
    val state = appState
    val scope = rememberCoroutineScope()
    // Sign-out keeps the address, so signing back in starts from it.
    var server by remember { mutableStateOf(state.settings.string(Settings.SERVER_URL) ?: "") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var quickConnectAvailable by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf<String?>(null) }
    var quickJob by remember { mutableStateOf<Job?>(null) }
    var disclaimer by remember { mutableStateOf("") }
    var editingHeaders by remember { mutableStateOf(false) }

    // Re-checked as the address is typed; the restart is the debounce.
    LaunchedEffect(server) {
        state.proxy.server = server
        quickConnectAvailable = false
        delay(500)
        if (server.isBlank()) { disclaimer = ""; return@LaunchedEffect }
        val text = async(Dispatchers.IO) { ServerMessage.fetchLoginDisclaimer(state.http, server) }
        val available = withContext(Dispatchers.IO) { QuickConnect.isEnabled(state.http, server) }
        quickConnectAvailable = available
        disclaimer = text.await()
    }

    fun submit() {
        if (busy || server.isBlank() || username.isBlank()) return
        busy = true
        error = null
        scope.launch {
            try {
                withContext(Dispatchers.IO) { state.signIn(server, username, password) }
            } catch (e: Exception) {
                error = e.message ?: "Sign-in failed"
            }
            busy = false
        }
    }

    fun startQuickConnect() {
        error = null
        quickJob?.cancel()
        quickJob = scope.launch {
            try {
                val started = withContext(Dispatchers.IO) { QuickConnect.initiate(state.http, server, state.identity, state.deviceId) }
                code = started.code
                val auth = withContext(Dispatchers.IO) {
                    QuickConnect.awaitApproval(state.http, server, started, state.identity, state.deviceId)
                }
                if (auth == null) error = "The code expired. Start again for a new one."
                else withContext(Dispatchers.IO) { state.signIn(server, started.secret) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Quick Connect failed"
            }
            code = null
        }
    }

    if (editingHeaders) {
        ProxyHeadersEditor(onDone = { editingHeaders = false }, modifier = Modifier.safeDrawingPadding())
        return
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Cascade", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 32.dp))
        Text("Sign in to your Jellyfin server", color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(server, { server = it.trim() }, label = { Text("Server") }, placeholder = { Text("https://jellyfin.example.com") },
            singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth())
        TextButton(onClick = { editingHeaders = true }, modifier = Modifier.align(Alignment.Start)) {
            val count = state.proxy.headers.size
            Text(if (count == 0) "Reverse proxy headers" else "Reverse proxy headers ($count)")
        }

        val shown = code
        if (shown != null) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Quick Connect", style = MaterialTheme.typography.titleMedium)
                    Text(shown, fontSize = 44.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    Text("Enter this code in Jellyfin on a device where you're already signed in: your profile, then Quick Connect.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    TextButton(onClick = { quickJob?.cancel(); code = null }) { Text("Cancel") }
                }
            }
        } else if (quickConnectAvailable) {
            OutlinedButton(onClick = ::startQuickConnect, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Sign in with Quick Connect") }
            Text("No password needed: approve a code from another device.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        OutlinedTextField(username, { username = it }, label = { Text("Username") }, singleLine = true,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Next), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { submit() }), modifier = Modifier.fillMaxWidth())
        // Shown, not swallowed: a sign-in that fails quietly looks like one that worked.
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(onClick = ::submit, enabled = !busy && server.isNotBlank() && username.isNotBlank(), modifier = Modifier.fillMaxWidth()) {
            Text(if (busy) "Signing in…" else "Sign in")
        }
        if (disclaimer.isNotEmpty()) {
            Text(disclaimer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp))
        }
    }
}
