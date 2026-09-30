import Testing
@testable import CascadeKit

private func tracks(_ ids: String...) -> [JfItem] {
    ids.map { JfItem(id: $0, name: $0) }
}

@Suite("Repeat mode")
struct RepeatModeTests {
    @Test func cyclesNoneAllOne() {
        #expect(RepeatMode.none.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .none)
    }
}

@Suite("Advancing at the end of a track")
struct AdvanceTests {
    @Test func playsTheNextTrack() {
        #expect(advanceOnEnd(length: 3, index: 0, repeatMode: .none) == .play(index: 1))
    }

    @Test func stopsAtTheEndWithoutRepeat() {
        #expect(advanceOnEnd(length: 3, index: 2, repeatMode: .none) == .stop)
    }

    @Test func wrapsWithRepeatAll() {
        #expect(advanceOnEnd(length: 3, index: 2, repeatMode: .all) == .play(index: 0))
    }

    @Test func repeatOneReplaysRatherThanAdvancing() {
        #expect(advanceOnEnd(length: 3, index: 0, repeatMode: .one) == .restart)
        #expect(advanceOnEnd(length: 3, index: 2, repeatMode: .one) == .restart)
    }

    @Test func anEmptyQueueStops() {
        #expect(advanceOnEnd(length: 0, index: -1, repeatMode: .all) == .stop)
    }
}

@Suite("Next and previous buttons")
struct ManualSkipTests {
    @Test func repeatOneStillSkipsOnAPress() {
        // The whole reason this is separate from advanceOnEnd: a player that
        // refused to skip because repeat-one was on would read as broken.
        #expect(manualNextIndex(length: 3, index: 0, repeatMode: .one) == 1)
    }

    @Test func stopsAtTheEndsWithoutRepeatAll() {
        #expect(manualNextIndex(length: 3, index: 2, repeatMode: .none) == nil)
        #expect(manualPreviousIndex(length: 3, index: 0, repeatMode: .none) == nil)
    }

    @Test func wrapsBothWaysWithRepeatAll() {
        #expect(manualNextIndex(length: 3, index: 2, repeatMode: .all) == 0)
        #expect(manualPreviousIndex(length: 3, index: 0, repeatMode: .all) == 2)
    }

    @Test func emptyQueueHasNowhereToGo() {
        #expect(manualNextIndex(length: 0, index: -1, repeatMode: .all) == nil)
        #expect(manualPreviousIndex(length: 0, index: -1, repeatMode: .all) == nil)
    }
}

@Suite("Shuffle")
struct ShuffleTests {
    @Test func onMovesTheCurrentTrackToTheFront() {
        // Otherwise the track you are listening to jumps to a random position
        // and everything before it is skipped the moment it ends.
        let before = QueueOrder(items: tracks("a", "b", "c", "d", "e"), index: 2)
        let after = setShuffle(before, on: true)
        #expect(after.index == 0)
        #expect(after.current?.id == "c")
        #expect(after.items.count == 5)
        #expect(Set(after.items.map(\.id)) == Set(["a", "b", "c", "d", "e"]))
    }

    @Test func onKeepsTheOriginalOrderForLater() {
        let before = QueueOrder(items: tracks("a", "b", "c"), index: 1)
        let after = setShuffle(before, on: true)
        #expect(after.unshuffled?.map(\.id) == ["a", "b", "c"])
    }

    @Test func turningItOnTwiceDoesNotReshuffle() {
        // A second shuffle would overwrite the saved order, so turning it off
        // afterwards could never restore anything.
        let once = setShuffle(QueueOrder(items: tracks("a", "b", "c"), index: 0), on: true)
        #expect(setShuffle(once, on: true) == once)
    }

    @Test func offRestoresOrderAndFindsTheTrackById() {
        // By id, not by index: an index means nothing across a reorder, and
        // reusing it lands on an unrelated track.
        let shuffledState = QueueOrder(items: tracks("c", "a", "b"), index: 0,
                                       unshuffled: tracks("a", "b", "c"))
        let restored = setShuffle(shuffledState, on: false)
        #expect(restored.items.map(\.id) == ["a", "b", "c"])
        #expect(restored.index == 2)
        #expect(restored.current?.id == "c")
        #expect(restored.unshuffled == nil)
    }

    @Test func offWithNothingSavedIsANoop() {
        let state = QueueOrder(items: tracks("a", "b"), index: 0)
        #expect(setShuffle(state, on: false) == state)
    }

    @Test func handlesAnEmptyQueue() {
        let empty = setShuffle(QueueOrder(), on: true)
        #expect(empty.index == -1)
        #expect(empty.items.isEmpty)
    }
}

@Suite("Song sorting")
struct SortTests {
    private var library: [JfItem] {
        var a = JfItem(id: "1", name: "Zebra")
        a.album = "Beta"; a.albumArtist = "Artist B"; a.dateCreated = "2024-01-01T00:00:00Z"
        var b = JfItem(id: "2", name: "Apple")
        b.album = "Alpha"; b.albumArtist = "Artist A"; b.dateCreated = "2026-01-01T00:00:00Z"
        return [a, b]
    }

    @Test func sortsByNameThenByOtherFields() {
        #expect(sortSongs(library, by: .name).map(\.id) == ["2", "1"])
        #expect(sortSongs(library, by: .album).map(\.id) == ["2", "1"])
        #expect(sortSongs(library, by: .artist).map(\.id) == ["2", "1"])
    }

    @Test func newestFirstIsDescendingByAdded() {
        #expect(sortSongs(library, by: .added, .descending).map(\.id) == ["2", "1"])
        #expect(sortSongs(library, by: .added, .ascending).map(\.id) == ["1", "2"])
    }

    @Test func missingValuesSortWithoutCrashing() {
        let sparse = [JfItem(id: "1"), JfItem(id: "2", name: "Named")]
        #expect(sortSongs(sparse, by: .album).count == 2)
    }

    @Test func tiesBreakOnNameSoTheOrderIsStable() {
        var a = JfItem(id: "1", name: "Second"); a.album = "Same"
        var b = JfItem(id: "2", name: "First");  b.album = "Same"
        #expect(sortSongs([a, b], by: .album).map(\.id) == ["2", "1"])
    }
}
