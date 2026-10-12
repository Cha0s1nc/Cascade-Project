package xyz.chaosinc.cascade.core

import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Longest a server error body may become as an error message before it is truncated. */
private const val MAX_ERROR_MESSAGE_LENGTH = 300

/** A refused or failed request. `status` is 0 when there was no HTTP response at all. */
class JellyfinException(val status: Int, message: String) : Exception(message)

/**
 * Who this app is to the server. `client` is the edition the server's Devices
 * screen shows beside the device ("Cascade Electron", "Cascade iOS"), `device`
 * the machine. Set once at startup by the app, before anything authenticates.
 */
data class ClientIdentity(val client: String, val device: String, val version: String) {
    companion object {
        /** The Android edition. Never "Cascade" alone: the server tells the editions apart by it. */
        const val ANDROID_EDITION = "Cascade Android"

        /**
         * A device name safe inside the quoted header value: printable ASCII
         * without quotes or backslashes, since anything else needs escaping the
         * server does not undo. Falls back to "Android" when nothing is left.
         */
        fun sanitizedDevice(name: String?): String {
            val kept = (name ?: "").filter { it in ' '..'~' && it != '"' && it != '\\' }.trim().take(64)
            return kept.ifEmpty { "Android" }
        }
    }
}

/**
 * The standard `Authorization: MediaBrowser ...` value, carrying the token when
 * there is one. That header (or `ApiKey` in a URL) is the only way Jellyfin 12
 * accepts a token by default: 12.0 turned off X-Emby-Token, X-Emby-Authorization
 * and api_key on new and upgraded servers. Jellyfin 10.11 accepts this form too.
 */
fun authHeader(identity: ClientIdentity, deviceId: String, token: String? = null): String {
    val base = "MediaBrowser Client=\"${identity.client}\", Device=\"${identity.device}\", " +
        "DeviceId=\"$deviceId\", Version=\"${identity.version}\""
    return if (token.isNullOrEmpty()) base else "$base, Token=\"$token\""
}

private val reasonPhrases = mapOf(
    400 to "Bad Request", 401 to "Unauthorized", 403 to "Forbidden", 404 to "Not Found",
    405 to "Method Not Allowed", 408 to "Request Timeout", 429 to "Too Many Requests",
    500 to "Internal Server Error", 502 to "Bad Gateway", 503 to "Service Unavailable", 504 to "Gateway Timeout",
)

/**
 * Turn a failed response into a short, readable message.
 *
 * Jellyfin's own error bodies are short plain text and worth showing as is. A
 * reverse proxy in front of a dead server answers instead with a whole HTML
 * error page, and dumping kilobytes of markup into a dialog fills the screen.
 * Detect that by content type or a leading `<` and fall back to the status line.
 */
fun errorMessage(status: Int, contentType: String?, body: String): String {
    val statusLine = "$status ${reasonPhrases[status] ?: "Error"}"
    val text = body.trim()
    if (text.isEmpty()) return statusLine
    if ((contentType ?: "").lowercase().contains("html") || text.startsWith("<")) return statusLine
    val collapsed = text.split(Regex("\\s+")).joinToString(" ")
    return if (collapsed.length > MAX_ERROR_MESSAGE_LENGTH) collapsed.take(MAX_ERROR_MESSAGE_LENGTH) + "…" else collapsed
}

/** Runs a call without blocking the coroutine's thread, cancelling the call with it. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { runCatching { cancel() } }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) { if (cont.isActive) cont.resumeWithException(e) }
        override fun onResponse(call: Call, response: Response) { cont.resume(response) { _, _, _ -> response.close() } }
    })
}

/** The body of a 2xx, or a JellyfinException with a readable message. Closes the response. */
internal fun Response.checkedBody(): String = use { r ->
    val text = r.body.string()
    // Every write path checks this. On desktop, five separate writes reported
    // success on an HTTP 403 because nothing looked at the status, and one
    // mutated local state anyway, so a refused delete looked like a done one.
    if (!r.isSuccessful) throw JellyfinException(r.code, errorMessage(r.code, r.header("Content-Type"), text))
    text
}

internal suspend fun OkHttpClient.send(request: Request): String = try {
    newCall(request).await().checkedBody()
} catch (e: JellyfinException) {
    throw e
} catch (e: IOException) {
    throw JellyfinException(0, e.message ?: "No HTTP response")
}

internal val jsonMediaType = "application/json".toMediaType()

/**
 * HTTP to one Jellyfin server as one user. Sign-in replaces the whole config,
 * so callers hold the client and swap what is inside it (`update`) rather
 * than rebuilding it and risking a stale copy still in use somewhere.
 */
class JellyfinClient(
    @Volatile private var config: ServerConfig,
    private val http: OkHttpClient,
    private val identity: ClientIdentity,
) {
    val currentConfig: ServerConfig get() = config
    val clientIdentity: ClientIdentity get() = identity
    val httpClient: OkHttpClient get() = http

    fun update(config: ServerConfig) { this.config = config }

    /**
     * Null values are skipped rather than sent as the text "null". Sorted so
     * the same params always build the same URL, which keeps them testable.
     */
    fun url(path: String, params: Map<String, String?> = emptyMap()): HttpUrl {
        val base = (config.url + path).toHttpUrlOrNull() ?: throw JellyfinException(0, "Bad URL for $path")
        return base.newBuilder().apply {
            params.toSortedMap().forEach { (k, v) -> if (v != null) addQueryParameter(k, v) }
        }.build()
    }

    private fun authed(url: HttpUrl) = Request.Builder().url(url)
        .header("Authorization", authHeader(identity, config.deviceId, config.token))

    suspend fun getText(path: String, params: Map<String, String?> = emptyMap()): String =
        http.send(authed(url(path, params)).get().build())

    suspend inline fun <reified T> get(path: String, params: Map<String, String?> = emptyMap()): T =
        CascadeJson.decodeFromString(serializer<T>(), getText(path, params))

    /** A reply whose shape belongs to a third party (SpicyLyrics, passed through by the plugin). */
    suspend fun getJson(path: String, params: Map<String, String?> = emptyMap()): JsonElement =
        CascadeJson.parseToJsonElement(getText(path, params))

    /** POST where the reply body is not wanted. Still throws on a bad status, which is the whole point. */
    suspend fun postRaw(path: String, bodyJson: String? = null, params: Map<String, String?> = emptyMap(),
                        timeoutSeconds: Long? = null): String {
        val body: RequestBody = (bodyJson ?: "").toRequestBody(if (bodyJson != null) jsonMediaType else null)
        val request = authed(url(path, params)).post(body).build()
        val client = timeoutSeconds?.let { http.newBuilder().callTimeout(it, TimeUnit.SECONDS).build() } ?: http
        return client.send(request)
    }

    suspend fun <B> post(path: String, body: B, serializer: KSerializer<B>, params: Map<String, String?> = emptyMap(),
                         timeoutSeconds: Long? = null): String =
        postRaw(path, CascadeJson.encodeToString(serializer, body), params, timeoutSeconds)

    suspend fun delete(path: String, params: Map<String, String?> = emptyMap()): String =
        http.send(authed(url(path, params)).delete().build())

    /**
     * A Primary image at a square box. Image loaders send no headers of ours,
     * so the token rides in the URL as `ApiKey`, never `api_key`: Jellyfin 12
     * refuses the latter by default, which once 401ed every video cover.
     */
    fun imageUrl(itemId: String, size: Int = 600): String =
        "${config.url}/Items/$itemId/Images/Primary?fillHeight=$size&fillWidth=$size&quality=90&ApiKey=${config.token}"

    /** Any image type at a given box, for art a square request would crop. */
    fun imageUrl(itemId: String, type: String, width: Int, height: Int): String =
        "${config.url}/Items/$itemId/Images/$type?fillHeight=$height&fillWidth=$width&quality=90&ApiKey=${config.token}"
}
