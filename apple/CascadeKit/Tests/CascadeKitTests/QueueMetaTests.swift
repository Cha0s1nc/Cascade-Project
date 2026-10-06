import Foundation
import Testing
@testable import CascadeKit

// Ported from test/queue.test.ts.
@Suite struct QueueMetaTests {
    private func track(_ id: String, seconds: Int?, album: (id: String, name: String)? = nil) -> JfItem {
        var item = JfItem(id: id, name: id, runTimeTicks: seconds.map { $0 * Lyrics.ticksPerSecond })
        item.albumId = album?.id
        item.album = album?.name
        return item
    }

    @Test func remainingIsWhatIsLeftOfTheCurrentTrackPlusTheRest() {
        let q = [track("a", seconds: 100), track("b", seconds: 200), track("c", seconds: 300), track("x", seconds: nil)]
        #expect(QueueMeta.remainingSeconds(q, index: 1, position: 50) == 150 + 300)
        // Past the end of the current track.
        #expect(QueueMeta.remainingSeconds(q, index: 1, position: 999) == 300)
        // No RunTimeTicks counts as 0.
        #expect(QueueMeta.remainingSeconds(q, index: 3, position: 0) == 0)
        #expect(QueueMeta.remainingSeconds(q, index: -1, position: 0) == 0)
        #expect(QueueMeta.remainingSeconds([], index: 0, position: 0) == 0)
    }

    @Test func spanFormatsUpToDays() {
        #expect(QueueMeta.formatSpan(30) == "<1m")
        #expect(QueueMeta.formatSpan(34 * 60 + 59) == "34m")
        #expect(QueueMeta.formatSpan(2 * 3600 + 5 * 60) == "2h 5m")
        #expect(QueueMeta.formatSpan(3 * 3600) == "3h")
        #expect(QueueMeta.formatSpan(25 * 3600 + 10 * 60) == "1d 1h")
        #expect(QueueMeta.formatSpan(48 * 3600) == "2d")
        #expect(QueueMeta.formatSpan(-5) == "<1m")
        #expect(QueueMeta.formatSpan(.nan) == "<1m")
    }

    @Test func theSourceIsTheAlbumOnlyWhenEveryTrackSharesIt() {
        let a = track("1", seconds: 1, album: ("A", "Fever"))
        #expect(QueueMeta.sourceFallback([a, track("2", seconds: 1, album: ("A", "Fever"))]) == "Fever")
        #expect(QueueMeta.sourceFallback([a, track("2", seconds: 1, album: ("B", "Fever"))]) == nil)
        #expect(QueueMeta.sourceFallback([track("1", seconds: 1)]) == nil)
        #expect(QueueMeta.sourceFallback([]) == nil)
    }

    @Test func summaryReadsLikeTheDesktops() {
        let q = (0..<40).map { track("t\($0)", seconds: 600) }
        let clock = { (_: Date) in "10:12 PM" }
        // Track 12 of 40, a minute in: 9 minutes left of it plus 28 more tracks.
        let s = QueueMeta.summary(queue: q, index: 11, position: 60, repeating: false, autoMix: false, formatTime: clock)
        #expect(s == "12 of 40 · 4h 49m · ends 10:12 PM")
        // Repeat or auto-mix: it never ends, so no end time.
        #expect(QueueMeta.summary(queue: q, index: 11, position: 60, repeating: true, autoMix: false, formatTime: clock) == "12 of 40")
        #expect(QueueMeta.summary(queue: q, index: 11, position: 60, repeating: false, autoMix: true, formatTime: clock) == "12 of 40")
        #expect(QueueMeta.summary(queue: [], index: 0, position: 0, repeating: false, autoMix: false) == "")
    }
}
