package xyz.chaosinc.cascade.core

// Editing a queue that is already playing: Play Next, Add to Queue, reorder,
// remove. Pure, like Queue.kt; the playback engine applies the result to the
// player's own playlist, because any of these can change what plays next.
//
// Two rules hold for every function here. The track playing now stays the
// track playing now, so `index` follows it wherever it moves. And while
// shuffle is on, `unshuffled` gets the same additions and removals, so turning
// shuffle off still finds everything that was added while it was on.

/** Insert right after the current track ("Play Next"). With nothing playing (index -1) that is the front. */
fun playingNext(state: QueueOrder, items: List<JfItem>): QueueOrder {
    val out = state.items.toMutableList().apply { addAll(maxOf(0, state.index + 1), items) }
    val saved = state.unshuffled?.toMutableList()?.apply {
        // After the current track in the saved order too, so it still plays
        // next-ish once shuffle is off rather than wherever it was appended.
        val c = state.current
        val at = c?.let { cur -> indexOfFirst { it.id == cur.id } }?.takeIf { it >= 0 }?.plus(1) ?: 0
        addAll(at, items)
    }
    return state.copy(items = out, unshuffled = saved)
}

/** Append to the end ("Add to Queue"). */
fun appending(state: QueueOrder, items: List<JfItem>): QueueOrder =
    state.copy(items = state.items + items, unshuffled = state.unshuffled?.plus(items))

/**
 * A further page of a list the queue was started from, at the end, minus
 * anything already queued: with several libraries selected, pages taken at
 * the same offset from each can overlap what came before.
 */
fun appendingPage(state: QueueOrder, page: List<JfItem>): QueueOrder {
    val queued = state.items.map { it.id }.toSet()
    return appending(state, page.filter { it.id !in queued })
}

/**
 * Move rows, `destination` being an offset in the list BEFORE the move (the
 * convention SwiftUI's onMove and most drag lists report). Only the play order
 * changes; the saved pre-shuffle order is the order being restored.
 */
fun moving(state: QueueOrder, from: Collection<Int>, destination: Int): QueueOrder {
    val valid = from.filter { it in state.items.indices }.distinct().sorted()
    if (valid.isEmpty()) return state
    val moved = valid.map { state.items[it] }
    val rest = state.items.toMutableList()
    for (i in valid.reversed()) rest.removeAt(i)
    val before = valid.count { it < maxOf(0, destination) }
    val at = (destination - before).coerceIn(0, rest.size)
    rest.addAll(at, moved)

    var index = state.index
    // Follow the current track by position, not by id: the same song can be
    // in the queue twice.
    if (state.index in state.items.indices) {
        val k = valid.indexOf(state.index)
        index = if (k >= 0) at + k else {
            val kept = state.index - valid.count { it < state.index }
            if (kept >= at) kept + moved.size else kept
        }
    }
    return state.copy(items = rest, index = index)
}

/** Remove rows. The current track is never removed, so the player cannot be left pointing at nothing. */
fun removing(state: QueueOrder, at: Collection<Int>): QueueOrder {
    val doomed = at.filter { it in state.items.indices && it != state.index }.distinct().sorted()
    if (doomed.isEmpty()) return state
    val removed = doomed.map { state.items[it] }
    val items = state.items.toMutableList()
    for (i in doomed.reversed()) items.removeAt(i)
    val index = if (state.index >= 0) state.index - doomed.count { it < state.index } else state.index
    val saved = state.unshuffled?.toMutableList()?.apply {
        // One saved copy per removed row, so a song queued twice and removed
        // once is still there once.
        for (item in removed) { val i = indexOfFirst { it.id == item.id }; if (i >= 0) removeAt(i) }
    }
    return state.copy(items = items, index = index, unshuffled = saved)
}

/** Songs like this one, seeded from a track, album or artist. GET /Items/{itemId}/InstantMix (10.11.11 spec). */
suspend fun JellyfinClient.instantMix(seedId: String, limit: Int = 50): List<JfItem> =
    get<JfItemsResponse>("/Items/$seedId/InstantMix", mapOf("userId" to currentConfig.userId, "limit" to limit.toString()))
        .items.orEmpty()

/** One item by id, with this user's data. Go to Album and Go to Artist use it. */
suspend fun JellyfinClient.item(id: String): JfItem =
    get("/Items/$id", mapOf("userId" to currentConfig.userId))
