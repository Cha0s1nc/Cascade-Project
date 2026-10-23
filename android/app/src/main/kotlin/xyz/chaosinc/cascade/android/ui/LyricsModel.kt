package xyz.chaosinc.cascade.android.ui

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.android.AppState
import xyz.chaosinc.cascade.android.BuildConfig
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.LyricsOutcome
import xyz.chaosinc.cascade.core.LyricsSourceChoice
import xyz.chaosinc.cascade.core.LyricsWaterfall

/** Where a track's lyrics stand: loading, found (or found to be absent) for that track. */
data class LyricsState(val itemId: String? = null, val loading: Boolean = false, val outcome: LyricsOutcome? = null)

/**
 * The playing track's lyrics, fetched through the waterfall only while
 * something shows them, and kept for the last few tracks so going back and
 * forth costs nothing. Everything that changes which lyrics a song gets (the
 * plugin turning up, server-only, the forced source) is part of the key.
 */
class LyricsModel(private val app: AppState) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val cache = object : LinkedHashMap<String, LyricsOutcome>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, LyricsOutcome>?) = size > 12
    }
    private val _state = MutableStateFlow(LyricsState())
    val state: StateFlow<LyricsState> = _state.asStateFlow()
    private var job: Job? = null
    private var key: String? = null

    val forced: LyricsSourceChoice get() = LyricsSourceChoice.fromStored(app.settings.string(LyricsSourceChoice.KEY))

    fun setForced(choice: LyricsSourceChoice) {
        app.settings.putString(LyricsSourceChoice.KEY, choice.raw)
        key = null
    }

    private fun keyFor(item: JfItem): String {
        val plugin = app.plugin.value
        return listOf(item.id, plugin?.api, plugin?.info?.capabilities?.sorted(), app.serverOnlyLyrics.value, forced.raw).joinToString("|")
    }

    fun load(item: JfItem?) {
        val client = app.session.value?.client
        if (item == null || client == null) { job?.cancel(); key = null; _state.value = LyricsState(); return }
        val k = keyFor(item)
        if (k == key) return
        key = k
        job?.cancel()
        cache[k]?.let { _state.value = LyricsState(item.id, false, it); return }
        _state.value = LyricsState(item.id, true, null)
        job = scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                LyricsWaterfall.fetch(LyricsWaterfall.Track.of(item), client, app.plugin.value, app.serverOnlyLyrics.value,
                    spotifyId = null, userAgent = "Cascade/${BuildConfig.VERSION_NAME} (Android; Jellyfin music client)", requested = forced)
            }
            cache[k] = outcome
            if (key == k) _state.value = LyricsState(item.id, false, outcome)
        }
    }
}
