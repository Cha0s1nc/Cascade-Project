package xyz.chaosinc.cascade.core

import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

// Extra HTTP headers for a Jellyfin server behind a reverse proxy (Cloudflare
// Access service tokens, Authelia). The proxy refuses any request without the
// header, so without this the app cannot even reach the sign-in. The pure part
// is ported from CascadeKit's ProxyHeaders.swift (itself the desktop's
// src/core/custom-headers.ts) with its tests. ProxyConnection applies them.

@Serializable
data class ProxyHeader(val name: String, val value: String)

data class ParsedHeaders(val headers: List<ProxyHeader>, val errors: List<String>)

object ProxyHeaders {
    /** More than this is a typo or a paste accident, not a proxy's requirements. */
    const val MAX_COUNT = 16
    const val MAX_VALUE_LENGTH = 4096

    /**
     * Names a person may not set: they would break the request framing or
     * replace Cascade's own sign-in. X-Emby-Authorization is Jellyfin's older
     * spelling of Authorization.
     */
    val blockedNames = setOf("authorization", "x-emby-authorization", "host", "content-length", "transfer-encoding")

    // RFC 9110 token characters.
    private val tokenCharacters = ("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").toSet()

    /** Why `name` cannot be a header name, or null when it can. */
    fun nameProblem(name: String): String? = when {
        name.isEmpty() -> "A header needs a name."
        name.any { it !in tokenCharacters } -> "\"${name.take(40)}\" is not a valid header name."
        name.lowercase() in blockedNames -> "$name cannot be overridden."
        else -> null
    }

    /** Why `value` cannot be a header value, or null when it can. */
    fun valueProblem(value: String): String? = when {
        value.isEmpty() -> "A header needs a value."
        value.length > MAX_VALUE_LENGTH -> "That header value is too long."
        // A line break would let a value smuggle in a second header.
        value.any { (it.code < 0x20 && it.code != 0x09) || it.code == 0x7f } -> "A header value cannot contain control characters."
        else -> null
    }

    /** The problem with adding `header` to `existing`, or null when it fits. */
    fun problem(header: ProxyHeader, existing: List<ProxyHeader>): String? {
        (nameProblem(header.name) ?: valueProblem(header.value))?.let { return it }
        if (existing.any { it.name.equals(header.name, ignoreCase = true) }) return "${header.name} is already listed."
        if (existing.size >= MAX_COUNT) return "At most $MAX_COUNT headers."
        return null
    }

    /** Headers from storage, which is untrusted: anything invalid, duplicated or past the cap is dropped, never repaired. */
    fun sanitized(list: List<ProxyHeader>): List<ProxyHeader> {
        val out = mutableListOf<ProxyHeader>()
        for (h in list) if (problem(h, out) == null) out += h
        return out
    }

    /** `Name: Value` lines, one per header, for a person to read or paste. */
    fun format(headers: List<ProxyHeader>): String = headers.joinToString("\n") { "${it.name}: ${it.value}" }

    /** The inverse of `format`. Blank lines and # comments are skipped. Every problem comes back with its line. */
    fun parse(text: String): ParsedHeaders {
        val headers = mutableListOf<ProxyHeader>()
        val errors = mutableListOf<String>()
        // Split on \r\n as well as \n and \r, so a Windows paste splits too.
        text.split(Regex("\r\n|\n|\r")).forEachIndexed { i, raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val colon = line.indexOf(':')
            if (colon < 0) { errors += "Line ${i + 1}: use Name: Value."; return@forEachIndexed }
            val header = ProxyHeader(line.substring(0, colon).trim(), line.substring(colon + 1).trim())
            val p = problem(header, headers)
            if (p != null) errors += "Line ${i + 1}: $p" else headers += header
        }
        return ParsedHeaders(headers, errors)
    }

    /**
     * scheme://host:port, the default port left off, and a WebSocket counted
     * as the HTTP it upgrades from. Null for anything not http, https, ws or wss.
     */
    fun origin(url: String): String? {
        val m = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://").find(url) ?: return null
        val http = when (m.groupValues[1].lowercase()) {
            "http", "ws" -> "http"
            "https", "wss" -> "https"
            else -> return null
        }
        // OkHttp only parses http(s), so a socket URL is read as its HTTP twin.
        val parsed = (http + url.substring(m.groupValues[1].length)).toHttpUrlOrNull() ?: return null
        return origin(parsed)
    }

    fun origin(url: HttpUrl): String? {
        if (url.host.isEmpty()) return null
        val defaultPort = HttpUrl.defaultPort(url.scheme)
        val port = if (url.port == defaultPort) "" else ":${url.port}"
        return "${url.scheme}://${url.host.lowercase()}$port"
    }

    /**
     * Whether a redirect may keep the headers: it stays on the same origin, or
     * it is the http to https upgrade of the same address. Any other port on
     * the host is another service.
     */
    fun redirectKeepsHeaders(from: String, to: String): Boolean {
        val x = origin(from) ?: return false
        val y = origin(to) ?: return false
        return x == y || (x.startsWith("http://") && x.replaceFirst("http://", "https://") == y)
    }

    /**
     * The headers to add to a request to `url`: all of them when it goes to the
     * Jellyfin server's own origin, none for any other host (lyrics providers,
     * the Waterfall relay). The path does not matter: the proxy answers for the
     * whole origin.
     */
    fun headersFor(url: String, server: String?, headers: List<ProxyHeader>): List<ProxyHeader> {
        if (headers.isEmpty() || server == null) return emptyList()
        val target = origin(url) ?: return emptyList()
        val mine = origin(server) ?: return emptyList()
        return if (target == mine) headers else emptyList()
    }
}

/**
 * Applies the proxy headers to everything that reaches the server: API calls,
 * images and the media streams all share the one OkHttpClient this interceptor
 * sits in. A network interceptor, so it runs again for each redirect and a
 * redirect to another host never carries them.
 */
class ProxyConnection : Interceptor {
    @Volatile var server: String? = null
    @Volatile var headers: List<ProxyHeader> = emptyList()
        set(value) { field = ProxyHeaders.sanitized(value) }

    fun headersToSend(url: String): List<ProxyHeader> {
        val direct = ProxyHeaders.headersFor(url, server, headers)
        if (direct.isNotEmpty()) return direct
        val s = server ?: return emptyList()
        // The http to https upgrade of the server's own address keeps them.
        return if (ProxyHeaders.origin(s)?.startsWith("http://") == true && ProxyHeaders.redirectKeepsHeaders(s, url)) headers
        else emptyList()
    }

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val extra = headersToSend(request.url.toString())
        if (extra.isEmpty()) return chain.proceed(request)
        val builder = request.newBuilder()
        for (h in extra) builder.header(h.name, h.value)
        return chain.proceed(builder.build())
    }
}
