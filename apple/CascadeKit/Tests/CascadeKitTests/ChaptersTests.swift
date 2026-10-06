import Foundation
import Testing
@testable import CascadeKit

// The chapter cases from test/playback.test.ts.
struct ChaptersTests {
    private func ch(_ pairs: [(Double, String)]) -> [Chapter] { pairs.map { Chapter(sec: $0.0, name: $0.1) } }

    @Test func listSortsDedupesNamesAndDropsChaptersPastTheEnd() {
        let list = chapterList([
            RawChapter(startPositionTicks: 600_000_000, name: "Middle"),
            RawChapter(startPositionTicks: 0, name: "  "),
            RawChapter(startPositionTicks: 600_000_000, name: "Duplicate"),
            RawChapter(startPositionTicks: 5_000_000_000, name: "After the end"),
            RawChapter(startPositionTicks: -1, name: "Negative"),
            RawChapter(startPositionTicks: nil, name: "No start"),
        ], runTimeTicks: 1_200_000_000)
        #expect(list == ch([(0, "Chapter 1"), (60, "Middle")]))
    }

    @Test func oneChapterOffersNothing() {
        #expect(chapterList([RawChapter(startPositionTicks: 0, name: "Film")]).isEmpty)
        #expect(chapterList(nil).isEmpty)
    }

    @Test func noRuntimeKeepsEveryChapter() {
        let list = chapterList([RawChapter(startPositionTicks: 0), RawChapter(startPositionTicks: 90_000_000_000)])
        #expect(list.map(\.sec) == [0, 9000])
    }

    @Test func atFindsTheChapterPlayingAtAPosition() {
        let c = ch([(0, "a"), (60, "b"), (120, "c")])
        #expect(chapterAt(c, 0) == 0)
        #expect(chapterAt(c, 59.9) == 0)
        #expect(chapterAt(c, 60) == 1)
        #expect(chapterAt(c, 5000) == 2)
        #expect(chapterAt(ch([(10, "x"), (20, "y")]), 5) == -1)
    }

    @Test func targetGoesForwardToTheNextStartAndBackLikeAPreviousButton() {
        let c = ch([(0, "a"), (60, "b"), (120, "c")])
        #expect(chapterTarget(c, 30, forward: true) == 60)
        #expect(chapterTarget(c, 130, forward: true) == nil)
        #expect(chapterTarget(c, 90, forward: false) == 60)
        #expect(chapterTarget(c, 61, forward: false) == 0)
        #expect(chapterTarget(c, 1, forward: false) == 0)
        #expect(chapterTarget(ch([(10, "x"), (20, "y")]), 5, forward: false) == nil)
        // Before the first chapter, forward still lands on it.
        #expect(chapterTarget(ch([(10, "x"), (20, "y")]), 5, forward: true) == 10)
    }

    /// The shape Jellyfin sends, through the same decoder the client uses.
    @Test func decodesTheServersShape() throws {
        struct Response: Decodable { var chapters: [RawChapter]? }
        let json = #"{"Chapters":[{"StartPositionTicks":0,"Name":"Opening","ImageDateModified":"0001-01-01T00:00:00Z"},{"StartPositionTicks":300000000}]}"#
        let r = try JSON.decoder.decode(Response.self, from: Data(json.utf8))
        #expect(chapterList(r.chapters) == ch([(0, "Opening"), (30, "Chapter 2")]))
    }
}
