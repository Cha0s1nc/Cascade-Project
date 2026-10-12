package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * What a Jellyfin server says to people outside of playback, as the desktop's
 * src/core/server-messages.ts reads it: a message an admin sends a session
 * from the dashboard (the DisplayMessage general command), and the login
 * disclaimer set in Branding, shown on the sign-in screen. Both are text from
 * the server, shown as plain text only.
 */
data class ServerMessage(val header: String, val text: String, val timeoutSeconds: Double?) {
    companion object {
        /** A DisplayMessage command's arguments (strings, as every general command's are), or null for nothing to show. */
        fun parse(args: Map<String, String?>): ServerMessage? {
            val header = clean(args["Header"], 120)
            val text = clean(args["Text"], 2000)
            if (header.isEmpty() && text.isEmpty()) return null
            val ms = args["TimeoutMs"]?.toDoubleOrNull()
            val timeout = ms?.takeIf { it.isFinite() && it > 0 }?.let { minOf(it, 600_000.0) / 1000 }
            return ServerMessage(header.ifEmpty { "Message from your server" }, text, timeout)
        }

        internal fun clean(v: String?, max: Int): String {
            val s = v ?: return ""
            val kept = s.filter { it == '\n' || it == '\t' || !Character.isISOControl(it) }
            return kept.trim().take(max)
        }

        /**
         * The Branding LoginDisclaimer as plain text. Jellyfin allows HTML there;
         * line breaks are kept, tags dropped, the common entities decoded.
         */
        fun loginDisclaimerText(raw: String?): String {
            var s = raw ?: return ""
            s = s.replace(Regex("<\\s*br\\s*/?>", RegexOption.IGNORE_CASE), "\n")
            s = s.replace(Regex("</\\s*(p|div|li|h[1-6])\\s*>", RegexOption.IGNORE_CASE), "\n")
            s = s.replace(Regex("<[^>]*>"), "")
            s = decodeEntities(s)
            val lines = s.split("\n").map { it.replace(Regex("[ \t]+"), " ").trim() }
            return lines.joinToString("\n").replace(Regex("\n{3,}"), "\n\n").trim().take(2000)
        }

        private val named = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ")

        private fun decodeEntities(s: String): String {
            val out = StringBuilder()
            var i = 0
            while (i < s.length) {
                val amp = s.indexOf('&', i)
                if (amp < 0) { out.append(s, i, s.length); break }
                out.append(s, i, amp)
                val semi = s.indexOf(';', amp + 1)
                if (semi > amp && semi - (amp + 1) <= 10) {
                    val name = s.substring(amp + 1, semi)
                    val decoded = when {
                        name.startsWith("#x") || name.startsWith("#X") -> name.drop(2).toIntOrNull(16)?.let(::scalar)
                        name.startsWith("#") -> name.drop(1).toIntOrNull()?.let(::scalar)
                        else -> named[name.lowercase()]
                    }
                    if (decoded != null) { out.append(decoded); i = semi + 1; continue }
                }
                out.append('&')
                i = amp + 1
            }
            return out.toString()
        }

        private fun scalar(code: Int): String? =
            if (code > 31 && Character.isValidCodePoint(code)) String(Character.toChars(code)) else null

        /** The server's login disclaimer, or "" for none or no answer. /Branding/Configuration needs no sign-in, which is the point. */
        suspend fun fetchLoginDisclaimer(http: OkHttpClient, serverUrl: String): String = runCatching {
            val base = serverBaseUrl(serverUrl) ?: return ""
            val url = base.toString().trimEnd('/') + "/Branding/Configuration"
            val text = http.send(Request.Builder().url(url).get().build())
            val obj = CascadeJson.parseToJsonElement(text) as? JsonObject
            loginDisclaimerText((obj?.get("LoginDisclaimer") as? JsonPrimitive)?.contentOrNull)
        }.getOrDefault("")
    }
}
