package xyz.chaosinc.cascade.core

// Queue ordering: sorting, shuffling, and what plays next. Pure, no player.
//
// These rules once lived in the desktop's renderer.js on the grounds that they
// were "mostly button painting". Only the buttons were. The decisions
// underneath, where shuffle puts the currently playing track and what a queue
// does when it runs out, are real behavior every platform has to reproduce
// exactly, so they live here and each host keeps its own buttons. Ported from
// CascadeKit's Queue.swift with its tests.

enum class SongSortField(val raw: String) {
    Name("name"), Artist("artist"), Album("album"), Added("added"), Played("played");

    companion object { fun of(raw: String?, fallback: SongSortField = Name) = entries.firstOrNull { it.raw == raw } ?: fallback }
}

enum class SortDirection { Ascending, Descending;
    /** Jellyfin's sortOrder value. */
    val serverValue: String get() = if (this == Descending) "Descending" else "Ascending"
    val flipped: SortDirection get() = if (this == Descending) Ascending else Descending
}

/** Sort key for a track. Strings are lowercased; ISO 8601 dates sort correctly as text. */
internal fun sortValue(item: JfItem, field: SongSortField): String = when (field) {
    SongSortField.Artist -> (item.albumArtist ?: item.artists?.firstOrNull() ?: "").lowercase()
    SongSortField.Album -> (item.album ?: "").lowercase()
    SongSortField.Added -> item.dateCreated ?: ""
    SongSortField.Played -> item.userData?.lastPlayedDate ?: ""
    SongSortField.Name -> (item.name ?: "").lowercase()
}

fun sortSongs(items: List<JfItem>, field: SongSortField, direction: SortDirection = SortDirection.Ascending): List<JfItem> =
    items.sortedWith { a, b ->
        val va = sortValue(a, field)
        val vb = sortValue(b, field)
        // Ties broken by name so the order is stable between two runs, which
        // matters when a whole album shares a sort key.
        if (va == vb) (a.name ?: "").compareTo(b.name ?: "")
        else if (direction == SortDirection.Descending) vb.compareTo(va) else va.compareTo(vb)
    }

/** None: play through and stop. All: wrap. One: replay this track. */
enum class RepeatMode(val raw: String) {
    None("none"), All("all"), One("one");

    /** Next mode for a press of the repeat button, matching the desktop's cycle. */
    val next: RepeatMode get() = when (this) { None -> All; All -> One; One -> None }

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } ?: None }
}

/** A queue and where we are in it. */
data class QueueOrder(
    val items: List<JfItem> = emptyList(),
    val index: Int = -1,
    /** The pre-shuffle order, kept only while shuffle is on. */
    val unshuffled: List<JfItem>? = null,
) {
    val current: JfItem? get() = items.getOrNull(index)
}

/**
 * Turn shuffle on or off, keeping the current track playing.
 *
 * Turning shuffle ON moves the current track to the front and sets the index
 * to 0 rather than shuffling around it. Without that, the track playing right
 * now would jump to a random position, and everything before it would be
 * skipped the moment it ended.
 *
 * Turning shuffle OFF restores the saved order and finds the current track in
 * it BY ID rather than reusing the index. An index means nothing across a
 * reorder, and reusing it lands on an unrelated track.
 */
fun setShuffle(state: QueueOrder, on: Boolean, random: kotlin.random.Random = kotlin.random.Random): QueueOrder {
    val currentId = state.current?.id
    if (on) {
        // Already on: leave it, or we reshuffle and lose the saved order.
        if (state.unshuffled != null) return state
        val items = state.items.shuffled(random).toMutableList()
        val at = items.indexOfFirst { it.id == currentId }
        if (currentId != null && at > 0) items.add(0, items.removeAt(at))
        return QueueOrder(items, if (items.isEmpty()) -1 else 0, state.items)
    }
    val items = state.unshuffled ?: return state
    val at = currentId?.let { id -> items.indexOfFirst { it.id == id } }?.takeIf { it >= 0 }
    return QueueOrder(items, at ?: 0, null)
}

/** What should happen when the current track finishes on its own. */
sealed interface QueueAdvance {
    data object Restart : QueueAdvance
    data class Play(val index: Int) : QueueAdvance
    data object Stop : QueueAdvance
}

/**
 * What plays when a track ends by itself. Separate from `manualNextIndex`
 * because repeat-one replays the track when it ends, but pressing next with
 * repeat-one on should move on: a player that refused to skip reads as broken.
 */
fun advanceOnEnd(length: Int, index: Int, repeatMode: RepeatMode): QueueAdvance {
    if (length <= 0) return QueueAdvance.Stop
    if (repeatMode == RepeatMode.One) return QueueAdvance.Restart
    val next = index + 1
    if (next < length) return QueueAdvance.Play(next)
    return if (repeatMode == RepeatMode.All) QueueAdvance.Play(0) else QueueAdvance.Stop
}

/** Index for the next button, or null if there is nothing to move to. */
fun manualNextIndex(length: Int, index: Int, repeatMode: RepeatMode): Int? {
    if (length <= 0) return null
    val next = index + 1
    if (next < length) return next
    return if (repeatMode == RepeatMode.All) 0 else null
}

/** Index for the previous button, or null if there is nothing to move to. */
fun manualPreviousIndex(length: Int, index: Int, repeatMode: RepeatMode): Int? {
    if (length <= 0) return null
    val previous = index - 1
    if (previous >= 0) return previous
    return if (repeatMode == RepeatMode.All) length - 1 else null
}
