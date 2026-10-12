package xyz.chaosinc.cascade.core

import kotlinx.coroutines.delay
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * A server address as typed, as a base URL, or null when it cannot be one. An
 * empty or scheme-less address would otherwise become a request that fails
 * later with a far less useful message.
 */
fun serverBaseUrl(serverUrl: String): HttpUrl? {
    val url = serverUrl.trim().trimEnd('/').toHttpUrlOrNull() ?: return null
    return if (url.host.isEmpty()) null else url
}

private fun endpoint(serverUrl: String, path: String): HttpUrl {
    val base = serverBaseUrl(serverUrl) ?: throw JellyfinException(0, "Not a valid server address")
    return (base.toString().trimEnd('/') + path).toHttpUrlOrNull()
        ?: throw JellyfinException(0, "Not a valid server address")
}

/**
 * Sign in with a username and password. Standalone rather than a client
 * method because it runs before there is any config to build a client with.
 * The body uses literal keys, so it needs no naming rule.
 */
suspend fun authenticate(http: OkHttpClient, identity: ClientIdentity, serverUrl: String, username: String,
                         password: String, deviceId: String): JfAuthResult {
    val body = buildJsonObject { put("Username", username); put("Pw", password) }.toString()
    val request = Request.Builder().url(endpoint(serverUrl, "/Users/AuthenticateByName"))
        .header("Authorization", authHeader(identity, deviceId))
        .post(body.toRequestBody(jsonMediaType))
        .build()
    return CascadeJson.decodeFromString(JfAuthResult.serializer(), http.send(request))
}

/** What the server hands back when a Quick Connect request starts, and on each poll. */
@Serializable
data class QuickConnectState(
    val secret: String,
    /** The code the user types on the other device. */
    val code: String,
    val authenticated: Boolean? = null,
)

// QuickConnect: sign in by approving a short code on a device that is already
// signed in (Jellyfin web, another app), instead of typing a password, so no
// password ever touches this app. Ported from CascadeKit's QuickConnect.swift,
// which was checked against the server's own spec (10.11.11):
//   GET  /QuickConnect/Enabled                -> Bool
//   POST /QuickConnect/Initiate               -> QuickConnectResult (needs the auth header)
//   GET  /QuickConnect/Connect?secret=        -> QuickConnectResult, 404 once expired
//   POST /Users/AuthenticateWithQuickConnect  {Secret} -> AuthenticationResult
object QuickConnect {
    /** How often to ask whether the code has been approved. */
    const val POLL_INTERVAL_MS = 2_000L
    /** Give up after this long, so a forgotten sign-in does not poll forever. */
    const val TIMEOUT_MS = 300_000L

    /**
     * The device id matters on the two authenticated calls: Jellyfin ties the
     * pending request to it, and it is what the resulting token is bound to.
     */
    fun initiateRequest(serverUrl: String, identity: ClientIdentity, deviceId: String): Request =
        Request.Builder().url(endpoint(serverUrl, "/QuickConnect/Initiate"))
            .header("Authorization", authHeader(identity, deviceId))
            .post(ByteArray(0).toRequestBody(null))
            .build()

    fun connectRequest(serverUrl: String, secret: String): Request =
        Request.Builder().url(endpoint(serverUrl, "/QuickConnect/Connect").newBuilder()
            .addQueryParameter("secret", secret).build()).get().build()

    fun authenticateRequest(serverUrl: String, secret: String, identity: ClientIdentity, deviceId: String): Request =
        Request.Builder().url(endpoint(serverUrl, "/Users/AuthenticateWithQuickConnect"))
            .header("Authorization", authHeader(identity, deviceId))
            .post(buildJsonObject { put("Secret", secret) }.toString().toRequestBody(jsonMediaType))
            .build()

    /**
     * Whether the server offers it. Never throws: a server that errors here
     * simply does not, and the password form is still there.
     */
    suspend fun isEnabled(http: OkHttpClient, serverUrl: String): Boolean = runCatching {
        val text = http.send(Request.Builder().url(endpoint(serverUrl, "/QuickConnect/Enabled")).get().build())
        (CascadeJson.parseToJsonElement(text) as? JsonPrimitive)?.booleanOrNull == true
    }.getOrDefault(false)

    /** Start a request and get the code to show the user. */
    suspend fun initiate(http: OkHttpClient, serverUrl: String, identity: ClientIdentity, deviceId: String): QuickConnectState =
        CascadeJson.decodeFromString(QuickConnectState.serializer(), http.send(initiateRequest(serverUrl, identity, deviceId)))

    /**
     * True once approved on the other device. A 404 means the request expired
     * or was cancelled server-side, and a network blip is just a missed poll:
     * both read as "not yet", and the timeout is what ends the wait.
     */
    suspend fun isApproved(http: OkHttpClient, serverUrl: String, secret: String): Boolean = runCatching {
        CascadeJson.decodeFromString(QuickConnectState.serializer(), http.send(connectRequest(serverUrl, secret)))
            .authenticated == true
    }.getOrDefault(false)

    /** Trade an approved secret for a real access token. */
    suspend fun authenticate(http: OkHttpClient, serverUrl: String, secret: String, identity: ClientIdentity,
                             deviceId: String): JfAuthResult =
        CascadeJson.decodeFromString(JfAuthResult.serializer(),
            http.send(authenticateRequest(serverUrl, secret, identity, deviceId)))

    /** Polls until approved, then signs in. Null on timeout; cancel the coroutine to stop early. */
    suspend fun awaitApproval(http: OkHttpClient, serverUrl: String, state: QuickConnectState,
                              identity: ClientIdentity, deviceId: String): JfAuthResult? {
        val deadline = System.currentTimeMillis() + TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            delay(POLL_INTERVAL_MS)
            if (isApproved(http, serverUrl, state.secret)) return authenticate(http, serverUrl, state.secret, identity, deviceId)
        }
        return null
    }

    /**
     * The code as the server wants it, or null when it cannot be one. Codes
     * are six digits; people paste them with spaces or a dash in the middle.
     */
    fun normalizedCode(raw: String): String? {
        val digits = raw.filter { !it.isWhitespace() && it != '-' }
        return if (digits.length == 6 && digits.all { it in '0'..'9' }) digits else null
    }
}

/**
 * Approve another device's Quick Connect code as the signed-in user.
 * POST /QuickConnect/Authorize?code= answers a Bool, and 404 for a code that
 * is not pending ("Error processing request.", no use to show as is).
 */
suspend fun JellyfinClient.authorizeQuickConnect(code: String) {
    val text = try {
        postRaw("/QuickConnect/Authorize", params = mapOf("code" to code))
    } catch (e: JellyfinException) {
        if (e.status == 404) throw JellyfinException(404,
            "No device is waiting with that code. Check it, or start again on the other device.")
        throw e
    }
    val approved = runCatching { (CascadeJson.parseToJsonElement(text) as? JsonPrimitive)?.booleanOrNull }.getOrNull() == true
    // A 200 that says false is still a refusal.
    if (!approved) throw JellyfinException(200, "The server did not approve that code.")
}
