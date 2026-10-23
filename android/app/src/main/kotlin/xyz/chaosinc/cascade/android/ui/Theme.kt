package xyz.chaosinc.cascade.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Cascade's accent, the desktop's default purple. */
val CascadeAccent = Color(0xFFB57BFF)

private val scheme = darkColorScheme(
    primary = CascadeAccent,
    onPrimary = Color(0xFF1A0B2E),
    secondary = Color(0xFF9C8CB8),
    background = Color(0xFF0E0D12),
    surface = Color(0xFF0E0D12),
    surfaceVariant = Color(0xFF1F1D26),
    surfaceContainer = Color(0xFF17161C),
    onSurface = Color(0xFFECE8F4),
    onSurfaceVariant = Color(0xFFB4AEC2),
)

/** Dark only, like the music apps it sits beside: art reads best on black. */
@Composable
fun CascadeTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, content = content)
}
