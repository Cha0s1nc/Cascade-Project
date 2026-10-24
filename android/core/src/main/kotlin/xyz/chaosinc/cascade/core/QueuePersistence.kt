package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import java.math.BigDecimal
import java.math.RoundingMode

// The queue as kept across a restart: the save and restore half of the
// desktop's src/core/queue.ts, via CascadeKit's QueuePersistence.swift. Item ids
// rather than items (refetched on restore, so a track deleted meanwhile just
// drops out), where playback was, and the original order when shuffled. Music
// only: a video or a radio station is not kept, and an empty queue keeps
// nothing.
//
// Stored data is untrusted, so the readers check it field by field, as the
// TypeScript does: one bad field costs that field, not the whole queue.

/** The desktop's `lastQueue` store key, holding this as a JSON string. */
const val LAST_QUEUE_KEY = "cascade.lastQueue"

/** More than this and a window around the current track is kept. */
const val SAVED_QUEUE_MAX = 2000

data class SavedQueue(val ids: List<String>, val index: Int, val positionSec: Double, val unshuffledIds: List<String>? = null) {
    /**
     * The same JSON the desktop writes: keys ids, index, positionSec and, only
     * when shuffled, unshuffledIds, in that (sorted) order, so an unchanged
     * queue is an identical string and the periodic save can skip writing it.
     */
    val json: String get() {
        fun list(l: List<String>) = l.joinToString(",", "[", "]") { JsonPrimitive(it).toString() }
        // A whole number prints without ".0", as JavaScript and Swift write it.
        val pos = BigDecimal.valueOf(positionSec).stripTrailingZeros().let { if (it.scale() < 0) it.setScale(0) else it }.toPlainString()
        val tail = unshuffledIds?.let { ",\"unshuffledIds\":${list(it)}" } ?: ""
        return "{\"ids\":${list(ids)},\"index\":$index,\"positionSec\":$pos$tail}"
    }
}

/** What to keep of a queue, or null when there is nothing worth keeping: no current track, or one that is not music. */
fun savedQueueOf(queue: List<JfItem>, index: Int, positionSec: Double, unshuffled: List<JfItem> = emptyList()): SavedQueue? {
    if (index !in queue.indices || queue[index].type != "Audio") return null
    // Past the cap, a window that holds the current track.
    val start = if (queue.size > SAVED_QUEUE_MAX) maxOf(0, minOf(index - 100, queue.size - SAVED_QUEUE_MAX)) else 0
    val ids = queue.subList(start, minOf(queue.size, start + SAVED_QUEUE_MAX)).map { it.id }
    val position = if (positionSec.isFinite()) BigDecimal.valueOf(maxOf(0.0, positionSec)).setScale(1, RoundingMode.HALF_UP).toDouble() else 0.0
    return SavedQueue(ids, index - start, position, unshuffled.takeIf { it.isNotEmpty() }?.take(SAVED_QUEUE_MAX)?.map { it.id })
}

/** A stored queue's JSON text, parsed. Null for text that is not JSON at all. */
fun parseSavedQueue(text: String?): JsonElement? =
    text?.let { runCatching { PlainJson.parseToJsonElement(it) }.getOrNull() }

/**
 * Jellyfin ids as they are on the wire: 32 hex digits, or a dashed GUID.
 * Checked because the ids go into a request, from storage anyone can edit.
 */
private fun isItemId(s: String) = s.length in 32..36 && s.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == '-' }

private fun idList(v: JsonElement?): List<String> =
    (v as? JsonArray).orEmpty().mapNotNull { e -> (e as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf(::isItemId) }
        .take(SAVED_QUEUE_MAX)

/** A JSON number that is a whole number. Never a boolean or a string. */
private fun wholeNumber(v: JsonElement?): Int? {
    val p = v as? JsonPrimitive ?: return null
    if (p.isString || p.booleanOrNull != null) return null
    val d = p.doubleOrNull ?: return null
    return if (d.isFinite() && d == Math.rint(d) && kotlin.math.abs(d) < 1e15) d.toInt() else null
}

/** Every id a stored queue needs fetched, or none if it is not a queue. */
fun savedQueueIds(saved: JsonElement?): List<String> {
    val s = saved as? JsonObject ?: return emptyList()
    return (idList(s["ids"]) + idList(s["unshuffledIds"])).distinct()
}

data class RestoredQueue(val queue: List<JfItem>, val index: Int, val positionSec: Double, val unshuffled: List<JfItem>)

/**
 * Rebuilds a stored queue from freshly fetched items (any order). If the
 * current track is gone, the next one still there becomes current, from its start.
 */
fun restoreQueue(saved: JsonElement?, items: List<JfItem>): RestoredQueue? {
    val s = saved as? JsonObject ?: return null
    val ids = idList(s["ids"])
    val byId = LinkedHashMap<String, JfItem>().apply { for (i in items) putIfAbsent(i.id, i) }
    val queue = ids.mapNotNull { byId[it] }
    if (queue.isEmpty()) return null
    val savedIndex = wholeNumber(s["index"])?.coerceIn(0, ids.size - 1) ?: 0
    val position = (s["positionSec"] as? JsonPrimitive)?.takeIf { !it.isString && it.booleanOrNull == null }
        ?.doubleOrNull?.takeIf { it.isFinite() }?.let { maxOf(0.0, it) } ?: 0.0
    val stillThere = byId.containsKey(ids[savedIndex])
    // Items kept before the saved current one: where it, or its successor, now sits.
    val before = ids.subList(0, savedIndex).count { byId.containsKey(it) }
    return RestoredQueue(queue, minOf(before, queue.size - 1), if (stillThere) position else 0.0,
        idList(s["unshuffledIds"]).mapNotNull { byId[it] })
}

/** The items for a stored queue, fetched in chunks: 2000 ids are far past a URL's reasonable length. */
suspend fun JellyfinClient.restoredItems(ids: List<String>): List<JfItem> {
    val all = mutableListOf<JfItem>()
    for (chunk in ids.chunked(100)) {
        all += get<JfItemsResponse>("/Items", mapOf(
            "userId" to currentConfig.userId, "ids" to chunk.joinToString(","),
            "fields" to "DateCreated,PrimaryImageAspectRatio,MediaSources",
        )).items.orEmpty()
    }
    return all
}
