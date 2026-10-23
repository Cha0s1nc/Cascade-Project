package xyz.chaosinc.cascade.android

import android.content.Context
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.OkHttpClient
import xyz.chaosinc.cascade.android.data.SecureStore
import xyz.chaosinc.cascade.android.data.Settings
import xyz.chaosinc.cascade.android.playback.PlaybackEngine
import xyz.chaosinc.cascade.core.CascadePluginProbe
import xyz.chaosinc.cascade.core.CascadePluginState
import xyz.chaosinc.cascade.core.ClientIdentity
import xyz.chaosinc.cascade.core.JellyfinClient
import xyz.chaosinc.cascade.core.JfAuthResult
import xyz.chaosinc.cascade.core.PlainJson
import xyz.chaosinc.cascade.core.ProxyConnection
import xyz.chaosinc.cascade.core.ProxyHeader
import xyz.chaosinc.cascade.core.ProxyHeaders
import xyz.chaosinc.cascade.core.QuickConnect
import xyz.chaosinc.cascade.core.ServerConfig
import xyz.chaosinc.cascade.core.authenticate
import xyz.chaosinc.cascade.core.probeCascadePlugin
import java.util.concurrent.TimeUnit

/** Who is signed in, and the client that talks to their server. */
data class Session(val config: ServerConfig, val client: JellyfinClient, val username: String?)

/**
 * Everything the app needs once, held in one place: the HTTP stack, who is
 * signed in, and the player. Screens read it through `CascadeApp.state`.
 * Nothing builds its own client, so there is exactly one session and one
 * player for the whole app, as on the iPhone (AppState.swift).
 */
class AppState(context: Context) {
    private val appContext = context.applicationContext
    val settings = Settings(appContext)
    val secure = SecureStore(appContext)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val identity = ClientIdentity(
        client = ClientIdentity.ANDROID_EDITION,
        device = ClientIdentity.sanitizedDevice(Build.MODEL),
        version = BuildConfig.VERSION_NAME,
    )

    /**
     * Reverse-proxy headers, applied to every request that reaches the server:
     * the API, artwork and the media streams all share `http`. Loaded before
     * anything is sent, since a proxy that wants a header refuses even the
     * first request without it.
     */
    val proxy = ProxyConnection().apply {
        headers = loadProxyHeaders()
        server = settings.string(Settings.SERVER_URL)
    }

    val http: OkHttpClient = OkHttpClient.Builder()
        .addNetworkInterceptor(proxy)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val _session = MutableStateFlow<Session?>(null)
    val session: StateFlow<Session?> = _session.asStateFlow()

    /** The server's Cascade plugin, once probed. Null until then and when absent. */
    private val _plugin = MutableStateFlow<CascadePluginState?>(null)
    val plugin: StateFlow<CascadePluginState?> = _plugin.asStateFlow()

    /** Lyrics only from the Cascade plugin (on by default, as on the iPhone). */
    private val _serverOnlyLyrics = MutableStateFlow(settings.bool(Settings.SERVER_ONLY_LYRICS, true))
    val serverOnlyLyrics: StateFlow<Boolean> = _serverOnlyLyrics.asStateFlow()
    fun setServerOnlyLyrics(on: Boolean) { settings.putBool(Settings.SERVER_ONLY_LYRICS, on); _serverOnlyLyrics.value = on }

    val engine = PlaybackEngine(appContext, this)

    /** The playing track's lyrics, shared by every screen that shows them. */
    val lyrics = xyz.chaosinc.cascade.android.ui.LyricsModel(this)

    val deviceId: String get() = settings.deviceId

    init { restore() }

    /**
     * Bring back the last session without asking for a password again. A
     * token revoked server-side since last launch shows as errors on every
     * screen until the person signs out, as on the iPhone.
     */
    private fun restore() {
        val token = secure.get(SecureStore.TOKEN) ?: return
        val url = settings.string(Settings.SERVER_URL) ?: return
        val userId = settings.string(Settings.USER_ID) ?: return
        val libraries = settings.stringList(Settings.LIBRARY_IDS).orEmpty()
        adopt(ServerConfig(url, token, userId, libraries, deviceId), settings.string(Settings.USERNAME), restoring = true)
    }

    suspend fun signIn(server: String, username: String, password: String) {
        proxy.server = server
        persist(server, authenticate(http, identity, server, username, password, deviceId))
    }

    /** Finish a Quick Connect sign-in. Saved exactly as a password sign-in is, so restore cannot tell them apart. */
    suspend fun signIn(server: String, quickConnectSecret: String) {
        proxy.server = server
        persist(server, QuickConnect.authenticate(http, server, quickConnectSecret, identity, deviceId))
    }

    private fun persist(server: String, auth: JfAuthResult) {
        val url = server.trim().trimEnd('/')
        proxy.server = url
        secure.set(SecureStore.TOKEN, auth.accessToken)
        settings.putString(Settings.SERVER_URL, url)
        settings.putString(Settings.USER_ID, auth.user.id)
        settings.putString(Settings.USERNAME, auth.user.name)
        adopt(ServerConfig(url, auth.accessToken, auth.user.id, emptyList(), deviceId), auth.user.name, restoring = false)
    }

    fun signOut() {
        engine.stopAndClear(clearSaved = true)
        secure.set(SecureStore.TOKEN, null)
        // The server address stays, so signing back in starts from it.
        settings.remove(Settings.USER_ID, Settings.LIBRARY_IDS, Settings.USERNAME)
        _plugin.value = null
        _session.value = null
        engine.attach(null)
    }

    /**
     * Which music libraries to browse; empty means all of them. Updates the
     * existing client rather than building a new session, so changing a
     * browsing preference never interrupts a track. The client is updated
     * before the published session changes: screens reload on that change.
     */
    fun setLibraries(ids: List<String>) {
        val s = _session.value ?: return
        val config = s.config.copy(libraryIds = ids)
        settings.putStringList(Settings.LIBRARY_IDS, ids)
        s.client.update(config)
        _session.value = s.copy(config = config)
    }

    private fun adopt(config: ServerConfig, username: String?, restoring: Boolean) {
        val client = JellyfinClient(config, http, identity)
        _session.value = Session(config, client, username)
        engine.attach(client)
        if (restoring) engine.restoreSavedQueue()
        _plugin.value = null
        scope.launch {
            val state = client.probeCascadePlugin()
            // Unknown counts as present: a network hiccup must not hide lyrics.
            if (_session.value?.client === client) _plugin.value = state.takeIf { it.probe != CascadePluginProbe.Absent }
        }
    }

    fun loadProxyHeaders(): List<ProxyHeader> = runCatching {
        ProxyHeaders.sanitized(PlainJson.decodeFromString(ListSerializer(ProxyHeader.serializer()),
            secure.get(SecureStore.PROXY_HEADERS) ?: return emptyList()))
    }.getOrDefault(emptyList())

    fun saveProxyHeaders(headers: List<ProxyHeader>) {
        val clean = ProxyHeaders.sanitized(headers)
        secure.set(SecureStore.PROXY_HEADERS,
            if (clean.isEmpty()) null else PlainJson.encodeToString(ListSerializer(ProxyHeader.serializer()), clean))
        proxy.headers = clean
    }
}
