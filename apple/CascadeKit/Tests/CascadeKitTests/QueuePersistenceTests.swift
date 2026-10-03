import Testing
import Foundation
@testable import CascadeKit

// The desktop's test/queue.test.ts cases for savedQueueOf and restoreQueue.
struct QueuePersistenceTests {
    private func id(_ c: Character) -> String { String(repeating: c, count: 32) }
    private func song(_ c: Character, type: String = "Audio") -> JfItem { JfItem(id: id(c), name: String(c), type: type) }

    @Test func keepsMusicQueuesByIdAndNothingElse() {
        let q = [song("1"), song("2"), song("3")]
        let saved = savedQueueOf(q, index: 1, positionSec: 42.34)
        #expect(saved == SavedQueue(ids: q.map(\.id), index: 1, positionSec: 42.3, unshuffledIds: nil))
        let shuffled = savedQueueOf(q, index: 0, positionSec: 0, unshuffled: [q[2], q[0], q[1]])
        #expect(shuffled?.unshuffledIds == [q[2].id, q[0].id, q[1].id])
        #expect(savedQueueOf([], index: 0, positionSec: 0) == nil)
        #expect(savedQueueOf([song("a", type: "Movie")], index: 0, positionSec: 10) == nil)
        // A radio station is not kept either, and an index past the end keeps nothing.
        #expect(savedQueueOf([song("a", type: "TvChannel")], index: 0, positionSec: 10) == nil)
        #expect(savedQueueOf(q, index: 3, positionSec: 0) == nil)
    }

    @Test func pastTheCapKeepsAWindowAroundTheCurrentTrack() {
        let q = (0..<(savedQueueMax + 500)).map { JfItem(id: String(format: "%032x", $0), name: "t", type: "Audio") }
        let early = savedQueueOf(q, index: 10, positionSec: 0)!
        #expect(early.ids.count == savedQueueMax)
        #expect(early.index == 10)
        let late = savedQueueOf(q, index: q.count - 5, positionSec: 0)!
        #expect(late.ids.count == savedQueueMax)
        #expect(late.ids[late.index] == q[q.count - 5].id)
        let middle = savedQueueOf(q, index: 1200, positionSec: 0)!
        #expect(middle.ids[middle.index] == q[1200].id)
    }

    @Test func jsonIsWhatTheDesktopWritesAndReadsBack() throws {
        let q = [song("a"), song("b")]
        let saved = try #require(savedQueueOf(q, index: 1, positionSec: 5.56, unshuffled: [q[1], q[0]]))
        #expect(saved.json == "{\"ids\":[\"\(id("a"))\",\"\(id("b"))\"],\"index\":1,\"positionSec\":5.6,\"unshuffledIds\":[\"\(id("b"))\",\"\(id("a"))\"]}")
        let back = restoreQueue(parseSavedQueue(saved.json), items: q)
        #expect(back?.queue.map(\.id) == [id("a"), id("b")])
        #expect(back?.index == 1)
        #expect(back?.unshuffled.map(\.id) == [id("b"), id("a")])
    }

    @Test func restoresInSavedOrderAndMovesPastDeletedTracks() throws {
        let saved: [String: Any] = ["ids": [id("a"), id("b"), id("c"), id("d")], "index": 2, "positionSec": 30,
                                    "unshuffledIds": [id("d"), id("a")]]
        #expect(savedQueueIds(saved) == [id("a"), id("b"), id("c"), id("d")])
        let items = [song("d"), song("c"), song("a")]   // server order, b deleted
        let r = try #require(restoreQueue(saved, items: items))
        #expect(r.queue.map(\.id) == [id("a"), id("c"), id("d")])
        #expect(r.index == 1)
        #expect(r.positionSec == 30)
        #expect(r.unshuffled.map(\.id) == [id("d"), id("a")])

        // Current track deleted: its successor, from the start.
        var gone = saved
        gone["index"] = 1
        let r2 = try #require(restoreQueue(gone, items: items))
        #expect(r2.queue[r2.index].id == id("c"))
        #expect(r2.positionSec == 0)
    }

    @Test func storedJunkIsNotAQueue() {
        let items = [song("a")]
        let junk: [Any?] = [nil, "x", 3, ["ids": "nope"], ["ids": ["../etc"]], ["ids": [id("z")]]]
        for j in junk { #expect(restoreQueue(j, items: items) == nil) }
        #expect(savedQueueIds("x").isEmpty)
        #expect(savedQueueIds(["ids": ["../etc", 5, id("a")]]) == [id("a")])
        #expect(parseSavedQueue("not json") == nil)
        #expect(parseSavedQueue(nil) == nil)
    }

    @Test func oneBadFieldCostsThatFieldNotTheQueue() throws {
        let items = [song("a"), song("b")]
        // A bad index becomes 0, a bad position becomes 0, a dashed GUID is accepted.
        let r = try #require(restoreQueue(["ids": [id("a"), id("b")], "index": 1.5, "positionSec": "soon"], items: items))
        #expect(r.index == 0 && r.positionSec == 0)
        let boolIndex = try #require(restoreQueue(["ids": [id("a"), id("b")], "index": true], items: items))
        #expect(boolIndex.index == 0)
        let out = try #require(restoreQueue(["ids": [id("a"), id("b")], "index": 99, "positionSec": -4], items: items))
        #expect(out.index == 1 && out.positionSec == 0)
        let dashed = "0123abcd-0123-4567-89ab-0123456789ab"
        #expect(savedQueueIds(["ids": [dashed]]) == [dashed])
    }
}
