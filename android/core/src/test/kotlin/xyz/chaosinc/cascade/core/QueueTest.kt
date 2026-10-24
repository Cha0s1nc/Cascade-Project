package xyz.chaosinc.cascade.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun tracks(vararg ids: String) = ids.map { JfItem(id = it, name = it) }

class QueueTest {
    @Test fun repeatCyclesNoneAllOne() {
        assertEquals(RepeatMode.All, RepeatMode.None.next)
        assertEquals(RepeatMode.One, RepeatMode.All.next)
        assertEquals(RepeatMode.None, RepeatMode.One.next)
    }

    @Test fun advancingAtTheEndOfATrack() {
        assertEquals(QueueAdvance.Play(1), advanceOnEnd(3, 0, RepeatMode.None))
        assertEquals(QueueAdvance.Stop, advanceOnEnd(3, 2, RepeatMode.None))
        assertEquals(QueueAdvance.Play(0), advanceOnEnd(3, 2, RepeatMode.All))
        assertEquals(QueueAdvance.Restart, advanceOnEnd(3, 0, RepeatMode.One))
        assertEquals(QueueAdvance.Restart, advanceOnEnd(3, 2, RepeatMode.One))
        assertEquals(QueueAdvance.Stop, advanceOnEnd(0, -1, RepeatMode.All))
    }

    @Test fun repeatOneStillSkipsOnAPress() {
        // A player that refused to skip because repeat-one was on would read as broken.
        assertEquals(1, manualNextIndex(3, 0, RepeatMode.One))
    }

    @Test fun skipsStopAtTheEndsWithoutRepeatAllAndWrapWithIt() {
        assertNull(manualNextIndex(3, 2, RepeatMode.None))
        assertNull(manualPreviousIndex(3, 0, RepeatMode.None))
        assertEquals(0, manualNextIndex(3, 2, RepeatMode.All))
        assertEquals(2, manualPreviousIndex(3, 0, RepeatMode.All))
        assertNull(manualNextIndex(0, -1, RepeatMode.All))
        assertNull(manualPreviousIndex(0, -1, RepeatMode.All))
    }

    @Test fun shuffleOnMovesTheCurrentTrackToTheFront() {
        // Otherwise the track you are listening to jumps to a random position
        // and everything before it is skipped the moment it ends.
        repeat(20) {
            val after = setShuffle(QueueOrder(tracks("a", "b", "c", "d", "e"), 2), on = true)
            assertEquals(0, after.index)
            assertEquals("c", after.current?.id)
            assertEquals(setOf("a", "b", "c", "d", "e"), after.items.map { it.id }.toSet())
            assertEquals(listOf("a", "b", "c", "d", "e"), after.unshuffled?.map { it.id })
        }
    }

    @Test fun turningShuffleOnTwiceDoesNotReshuffle() {
        val once = setShuffle(QueueOrder(tracks("a", "b", "c"), 0), on = true)
        assertEquals(once, setShuffle(once, on = true))
    }

    @Test fun shuffleOffRestoresOrderAndFindsTheTrackById() {
        val restored = setShuffle(QueueOrder(tracks("c", "a", "b"), 0, tracks("a", "b", "c")), on = false)
        assertEquals(listOf("a", "b", "c"), restored.items.map { it.id })
        assertEquals(2, restored.index)
        assertNull(restored.unshuffled)
        val state = QueueOrder(tracks("a", "b"), 0)
        assertEquals(state, setShuffle(state, on = false))
        val empty = setShuffle(QueueOrder(), on = true)
        assertEquals(-1, empty.index)
    }

    private val library = listOf(
        JfItem(id = "1", name = "Zebra", album = "Beta", albumArtist = "Artist B", dateCreated = "2024-01-01T00:00:00Z"),
        JfItem(id = "2", name = "Apple", album = "Alpha", albumArtist = "Artist A", dateCreated = "2026-01-01T00:00:00Z"),
    )

    @Test fun songSorting() {
        assertEquals(listOf("2", "1"), sortSongs(library, SongSortField.Name).map { it.id })
        assertEquals(listOf("2", "1"), sortSongs(library, SongSortField.Album).map { it.id })
        assertEquals(listOf("2", "1"), sortSongs(library, SongSortField.Artist).map { it.id })
        assertEquals(listOf("2", "1"), sortSongs(library, SongSortField.Added, SortDirection.Descending).map { it.id })
        assertEquals(listOf("1", "2"), sortSongs(library, SongSortField.Added).map { it.id })
        assertEquals(2, sortSongs(listOf(JfItem("1"), JfItem("2", "Named")), SongSortField.Album).size)
        val a = JfItem("1", "Second", album = "Same")
        val b = JfItem("2", "First", album = "Same")
        assertEquals(listOf("2", "1"), sortSongs(listOf(a, b), SongSortField.Album).map { it.id })
    }
}

class QueueActionsTest {
    private fun items(vararg ids: String) = ids.map { JfItem(it) }
    private fun ids(q: QueueOrder) = q.items.joinToString("") { it.id }

    @Test fun playNextGoesRightAfterTheCurrentTrack() {
        val q = playingNext(QueueOrder(items("a", "b", "c"), 1), items("x", "y"))
        assertEquals("abxyc", ids(q))
        assertEquals("b", q.current?.id)
    }

    @Test fun playNextWithNothingPlayingGoesToTheFront() {
        val q = playingNext(QueueOrder(), items("x"))
        assertEquals("x", ids(q))
        assertEquals(-1, q.index)
    }

    @Test fun playNextWhileShuffledAlsoLandsAfterTheCurrentTrackInTheSavedOrder() {
        val q = playingNext(QueueOrder(items("c", "a", "b"), 0, items("a", "b", "c")), items("x"))
        assertEquals("cxab", ids(q))
        assertEquals("abcx", q.unshuffled?.joinToString("") { it.id })
        assertEquals("c", setShuffle(q, on = false).current?.id)
    }

    @Test fun aPageSkipsWhatIsAlreadyQueued() {
        val q = appendingPage(QueueOrder(items("a", "b"), 0), items("b", "c", "d"))
        assertEquals("abcd", ids(q))
        assertEquals("a", q.current?.id)
    }

    @Test fun appendingAddsToBothOrders() {
        val q = appending(QueueOrder(items("b", "a"), 0, items("a", "b")), items("x"))
        assertEquals("bax", ids(q))
        assertEquals("abx", q.unshuffled?.joinToString("") { it.id })
        assertEquals(0, q.index)
    }

    @Test fun movingARowDownUsesBeforeTheMoveOffsets() {
        // "Drop before row 3" for dragging row 0 below row 2.
        val q = moving(QueueOrder(items("a", "b", "c", "d"), 0), listOf(0), 3)
        assertEquals("bcad", ids(q))
        assertEquals(2, q.index)
    }

    @Test fun movingARowUpPastTheCurrentTrackShiftsTheIndex() {
        val q = moving(QueueOrder(items("a", "b", "c", "d"), 1), listOf(3), 0)
        assertEquals("dabc", ids(q))
        assertEquals("b", q.current?.id)
    }

    @Test fun movingFollowsTheCurrentTrackNotItsId() {
        // The same song twice; looking it up by id would land on the wrong copy.
        val q = moving(QueueOrder(items("a", "b", "a"), 0), listOf(2), 0)
        assertEquals("aab", ids(q))
        assertEquals(1, q.index)
    }

    @Test fun movingOutOfRangeChangesNothing() {
        val start = QueueOrder(items("a", "b"), 0)
        assertEquals(start, moving(start, listOf(5), 0))
    }

    @Test fun removingKeepsTheCurrentTrackAndItsIndex() {
        val q = removing(QueueOrder(items("a", "b", "c", "d"), 2), listOf(0, 2, 3))
        assertEquals("bc", ids(q))
        assertEquals("c", q.current?.id)
    }

    @Test fun removingWhileShuffledRemovesOneSavedCopy() {
        val q = removing(QueueOrder(items("b", "a", "a"), 0, items("a", "a", "b")), listOf(1))
        assertEquals("ba", ids(q))
        assertEquals("ab", q.unshuffled?.joinToString("") { it.id })
    }
}

// The desktop's test/queue.test.ts cases for savedQueueOf and restoreQueue.
class QueuePersistenceTest {
    private fun id(c: Char) = c.toString().repeat(32)
    private fun song(c: Char, type: String = "Audio") = JfItem(id(c), c.toString(), type)
    private fun obj(vararg pairs: Pair<String, Any?>): JsonElement = buildJsonObject {
        for ((k, v) in pairs) when (v) {
            is List<*> -> put(k, buildJsonArray { v.forEach { add(when (it) { is Number -> JsonPrimitive(it); else -> JsonPrimitive(it.toString()) }) } })
            is Number -> put(k, v)
            is Boolean -> put(k, v)
            is String -> put(k, v)
        }
    }

    @Test fun keepsMusicQueuesByIdAndNothingElse() {
        val q = listOf(song('1'), song('2'), song('3'))
        assertEquals(SavedQueue(q.map { it.id }, 1, 42.3, null), savedQueueOf(q, 1, 42.34))
        assertEquals(listOf(q[2].id, q[0].id, q[1].id), savedQueueOf(q, 0, 0.0, listOf(q[2], q[0], q[1]))?.unshuffledIds)
        assertNull(savedQueueOf(emptyList(), 0, 0.0))
        assertNull(savedQueueOf(listOf(song('a', "Movie")), 0, 10.0))
        assertNull(savedQueueOf(listOf(song('a', "TvChannel")), 0, 10.0))
        assertNull(savedQueueOf(q, 3, 0.0))
    }

    @Test fun pastTheCapKeepsAWindowAroundTheCurrentTrack() {
        val q = (0 until SAVED_QUEUE_MAX + 500).map { JfItem("%032x".format(it), "t", "Audio") }
        val early = savedQueueOf(q, 10, 0.0)!!
        assertEquals(SAVED_QUEUE_MAX, early.ids.size)
        assertEquals(10, early.index)
        val late = savedQueueOf(q, q.size - 5, 0.0)!!
        assertEquals(SAVED_QUEUE_MAX, late.ids.size)
        assertEquals(q[q.size - 5].id, late.ids[late.index])
        val middle = savedQueueOf(q, 1200, 0.0)!!
        assertEquals(q[1200].id, middle.ids[middle.index])
    }

    @Test fun jsonIsWhatTheDesktopWritesAndReadsBack() {
        val q = listOf(song('a'), song('b'))
        val saved = savedQueueOf(q, 1, 5.56, listOf(q[1], q[0]))!!
        assertEquals("{\"ids\":[\"${id('a')}\",\"${id('b')}\"],\"index\":1,\"positionSec\":5.6,\"unshuffledIds\":[\"${id('b')}\",\"${id('a')}\"]}", saved.json)
        assertEquals("{\"ids\":[\"${id('a')}\"],\"index\":0,\"positionSec\":30}", SavedQueue(listOf(id('a')), 0, 30.0).json)
        val back = restoreQueue(parseSavedQueue(saved.json), q)!!
        assertEquals(listOf(id('a'), id('b')), back.queue.map { it.id })
        assertEquals(1, back.index)
        assertEquals(listOf(id('b'), id('a')), back.unshuffled.map { it.id })
    }

    @Test fun restoresInSavedOrderAndMovesPastDeletedTracks() {
        val saved = obj("ids" to listOf(id('a'), id('b'), id('c'), id('d')), "index" to 2, "positionSec" to 30,
            "unshuffledIds" to listOf(id('d'), id('a')))
        assertEquals(listOf(id('a'), id('b'), id('c'), id('d')), savedQueueIds(saved))
        val items = listOf(song('d'), song('c'), song('a'))   // server order, b deleted
        val r = restoreQueue(saved, items)!!
        assertEquals(listOf(id('a'), id('c'), id('d')), r.queue.map { it.id })
        assertEquals(1, r.index)
        assertEquals(30.0, r.positionSec, 0.0)
        assertEquals(listOf(id('d'), id('a')), r.unshuffled.map { it.id })

        // Current track deleted: its successor, from the start.
        val gone = obj("ids" to listOf(id('a'), id('b'), id('c'), id('d')), "index" to 1, "positionSec" to 30)
        val r2 = restoreQueue(gone, items)!!
        assertEquals(id('c'), r2.queue[r2.index].id)
        assertEquals(0.0, r2.positionSec, 0.0)
    }

    @Test fun storedJunkIsNotAQueue() {
        val items = listOf(song('a'))
        val junk: List<JsonElement?> = listOf(null, JsonPrimitive("x"), JsonPrimitive(3), obj("ids" to "nope"),
            obj("ids" to listOf("../etc")), obj("ids" to listOf(id('z'))))
        for (j in junk) assertNull(restoreQueue(j, items))
        assertTrue(savedQueueIds(JsonPrimitive("x")).isEmpty())
        assertEquals(listOf(id('a')), savedQueueIds(obj("ids" to listOf("../etc", 5, id('a')))))
        assertNull(parseSavedQueue("not json"))
        assertNull(parseSavedQueue(null))
    }

    @Test fun oneBadFieldCostsThatFieldNotTheQueue() {
        val items = listOf(song('a'), song('b'))
        val r = restoreQueue(obj("ids" to listOf(id('a'), id('b')), "index" to 1.5, "positionSec" to "soon"), items)!!
        assertEquals(0, r.index)
        assertEquals(0.0, r.positionSec, 0.0)
        val boolIndex = restoreQueue(obj("ids" to listOf(id('a'), id('b')), "index" to true), items)!!
        assertEquals(0, boolIndex.index)
        val out = restoreQueue(obj("ids" to listOf(id('a'), id('b')), "index" to 99, "positionSec" to -4), items)!!
        assertEquals(1, out.index)
        assertEquals(0.0, out.positionSec, 0.0)
        val dashed = "0123abcd-0123-4567-89ab-0123456789ab"
        assertEquals(listOf(dashed), savedQueueIds(obj("ids" to listOf(dashed))))
        assertNotNull(JsonArray(emptyList()))
    }
}
