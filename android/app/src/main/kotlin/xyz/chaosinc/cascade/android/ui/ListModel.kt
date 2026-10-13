package xyz.chaosinc.cascade.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import xyz.chaosinc.cascade.core.JfItem
import xyz.chaosinc.cascade.core.mergeLibraryCopies
import xyz.chaosinc.cascade.core.sortedLikeServer

/**
 * A browsing list that loads in pages of 200, as the iPhone's Songs and Albums
 * do (loadPaged in Navigation.swift), and survives going into an item and
 * back (it lives with the screen's navigation entry).
 *
 * The offset is a server offset applied to every selected library, so it
 * moves by the page size, not by how many items came back merged. With more
 * than one library, everything loaded is merged and re-sorted on each page:
 * a song sits at a different offset in each library, so its copies can
 * arrive pages apart, and a later page from one library can hold items that
 * belong ahead of another's. The list ends when a page brings nothing new.
 *
 * `bind` with a new key (another sort, a filter, a library change) starts
 * over; the same key keeps what is loaded.
 */
class ListModel : ViewModel() {
    var items by mutableStateOf<List<JfItem>>(emptyList()); private set
    var loading by mutableStateOf(false); private set
    var error by mutableStateOf<String?>(null); private set
    var exhausted by mutableStateOf(false); private set

    private var key: Any? = null
    private var pageSize: Int? = null
    private var loader: (suspend (start: Int, limit: Int?) -> List<JfItem>)? = null
    private var job: Job? = null
    private var raw = emptyList<JfItem>()
    private var seen = HashSet<String>()
    private var nextStart = 0
    private var sortBy: String? = null
    private var sortOrder: String? = null
    private var generations = 0

    fun bind(key: Any, pageSize: Int? = PAGE, sortBy: String? = null, sortOrder: String? = null,
             loader: suspend (start: Int, limit: Int?) -> List<JfItem>) {
        if (key == this.key) return
        this.key = key
        this.pageSize = pageSize
        this.loader = loader
        this.sortBy = sortBy
        this.sortOrder = sortOrder
        job?.cancel()
        generations++
        raw = emptyList()
        seen = HashSet()
        nextStart = 0
        items = emptyList()
        exhausted = false
        error = null
        loading = false
        loadMore()
    }

    /** Asks again from the top, keeping the key. */
    fun refresh() {
        val k = key ?: return
        val l = loader ?: return
        key = null
        bind(k, pageSize, sortBy, sortOrder, l)
    }

    fun loadMore() {
        if (loading || exhausted) return
        val load = loader ?: return
        loading = true
        val start = nextStart
        val generation = ++generations
        job = viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) { load(start, pageSize) }
                val fresh = page.filter { seen.add(it.id) }
                raw = raw + fresh
                val libraries = raw.mapTo(HashSet()) { it.sourceLibrary ?: -1 }.size
                items = if (libraries <= 1) raw
                else withContext(Dispatchers.Default) { sortedLikeServer(mergeLibraryCopies(raw), sortBy, sortOrder) }
                nextStart = start + (pageSize ?: 0)
                exhausted = pageSize == null || fresh.isEmpty()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Could not load"
            } finally {
                // A load cancelled by a new bind finishes after the new one has
                // started; it must not mark that one as done.
                if (generation == generations) loading = false
            }
        }
    }

    companion object { const val PAGE = 200 }
}
