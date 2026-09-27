import Foundation
import Testing
@testable import CascadeKit

@Suite struct QueueActionsTests {
    private func items(_ ids: String...) -> [JfItem] { ids.map { JfItem(id: $0) } }
    private func ids(_ q: QueueOrder) -> String { q.items.map(\.id).joined() }

    @Test func playNextGoesRightAfterTheCurrentTrack() {
        let q = playingNext(QueueOrder(items: items("a", "b", "c"), index: 1), items("x", "y"))
        #expect(ids(q) == "abxyc")
        #expect(q.current?.id == "b")
    }

    @Test func playNextWithNothingPlayingGoesToTheFront() {
        let q = playingNext(QueueOrder(), items("x"))
        #expect(ids(q) == "x")
        #expect(q.index == -1)
    }

    @Test func playNextWhileShuffledAlsoLandsAfterTheCurrentTrackInTheSavedOrder() {
        let q = playingNext(QueueOrder(items: items("c", "a", "b"), index: 0, unshuffled: items("a", "b", "c")), items("x"))
        #expect(ids(q) == "cxab")
        #expect(q.unshuffled?.map(\.id).joined() == "abcx")
        #expect(setShuffle(q, on: false).current?.id == "c")
    }

    @Test func appendingAddsToBothOrders() {
        let q = appending(QueueOrder(items: items("b", "a"), index: 0, unshuffled: items("a", "b")), items("x"))
        #expect(ids(q) == "bax")
        #expect(q.unshuffled?.map(\.id).joined() == "abx")
        #expect(q.index == 0)
    }

    @Test func movingARowDownUsesOnMoveOffsets() {
        // onMove reports "drop before row 3" for dragging row 0 below row 2.
        let q = moving(QueueOrder(items: items("a", "b", "c", "d"), index: 0), from: [0], to: 3)
        #expect(ids(q) == "bcad")
        #expect(q.current?.id == "a")
        #expect(q.index == 2)
    }

    @Test func movingARowUpPastTheCurrentTrackShiftsTheIndex() {
        let q = moving(QueueOrder(items: items("a", "b", "c", "d"), index: 1), from: [3], to: 0)
        #expect(ids(q) == "dabc")
        #expect(q.current?.id == "b")
    }

    @Test func movingFollowsTheCurrentTrackNotItsId() {
        // The same song twice; the first copy is playing and the second is
        // dragged above it. Looking it up by id would land on the wrong copy.
        let q = moving(QueueOrder(items: items("a", "b", "a"), index: 0), from: [2], to: 0)
        #expect(ids(q) == "aab")
        #expect(q.index == 1)
    }

    @Test func movingOutOfRangeChangesNothing() {
        let start = QueueOrder(items: items("a", "b"), index: 0)
        #expect(moving(start, from: [5], to: 0) == start)
    }

    @Test func removingKeepsTheCurrentTrackAndItsIndex() {
        let q = removing(QueueOrder(items: items("a", "b", "c", "d"), index: 2), at: [0, 2, 3])
        #expect(ids(q) == "bc")
        #expect(q.current?.id == "c")
    }

    @Test func removingWhileShuffledRemovesOneSavedCopy() {
        let q = removing(QueueOrder(items: items("b", "a", "a"), index: 0, unshuffled: items("a", "a", "b")), at: [1])
        #expect(ids(q) == "ba")
        #expect(q.unshuffled?.map(\.id).joined() == "ab")
    }
}
