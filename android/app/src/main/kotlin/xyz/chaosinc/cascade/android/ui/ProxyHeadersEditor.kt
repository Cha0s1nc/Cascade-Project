package xyz.chaosinc.cascade.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import xyz.chaosinc.cascade.core.ProxyHeaders

/**
 * Headers for a server behind a reverse proxy (Cloudflare Access service
 * tokens, Authelia), one `Name: Value` per line. They go to the server's own
 * address only, never to lyrics providers or anyone else, and are kept
 * encrypted with the token.
 */
@Composable
fun ProxyHeadersEditor(onDone: () -> Unit, modifier: Modifier = Modifier) {
    val state = appState
    var text by remember { mutableStateOf(ProxyHeaders.format(state.proxy.headers)) }
    var errors by remember { mutableStateOf<List<String>>(emptyList()) }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Reverse proxy headers", style = MaterialTheme.typography.headlineSmall)
        Text("For a server behind Cloudflare Access or a similar proxy. One per line, as Name: Value. Sent only to your server's own address.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        OutlinedTextField(text, { text = it; errors = emptyList() }, modifier = Modifier.fillMaxWidth().height(200.dp),
            textStyle = TextStyle(fontFamily = FontFamily.Monospace), placeholder = { Text("CF-Access-Client-Id: ...") },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
        errors.forEach { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = onDone) { Text("Cancel") }
            Button(onClick = {
                val parsed = ProxyHeaders.parse(text)
                if (parsed.errors.isNotEmpty()) errors = parsed.errors
                else { state.saveProxyHeaders(parsed.headers); onDone() }
            }) { Text("Save") }
        }
    }
}
