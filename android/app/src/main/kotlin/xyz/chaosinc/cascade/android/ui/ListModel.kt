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

/**
 * A browsing list that loads in pages of 200, as the iPhone's Songs and Albums
 * do, and survives going into an item and back (it lives with the screen's
 * navigation entry). Every page is merged with what came before, because a
 * copy of an album in a second library can land on a later page.
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

    fun bind(key: Any, pageSize: Int? = PAGE, loader: suspend (start: Int, limit: Int?) -> List<JfItem>) {
        if (key == this.key) return
        this.key = key
        this.pageSize = pageSize
        this.loader = loader
        job?.cancel()
        raw = emptyList()
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
        bind(k, pageSize, l)
    }

    fun loadMore() {
        if (loading || exhausted) return
        val load = loader ?: return
        loading = true
        val start = raw.size
        job = viewModelScope.launch {
            try {
                val page = withContext(Dispatchers.IO) { load(start, pageSize) }
                raw = raw + page
                items = mergeLibraryCopies(raw)
                // A short page is the last one. Several libraries each return a
                // page, so "short" is judged on what came back in total.
                exhausted = pageSize == null || page.size < pageSize!!
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.message ?: "Could not load"
            } finally {
                loading = false
            }
        }
    }

    companion object { const val PAGE = 200 }
}
