import Foundation
import Testing
@testable import CascadeKit

struct ChaptersTests {
    private let t = 10_000_000

    @Test func sortsDedupesNamesAndDropsChaptersPastTheEnd() {
        let list = Chapters.list([
            JfChapter(name: "Middle", startPositionTicks: 600 * t),
            JfChapter(name: "", startPositionTicks: 0),
            JfChapter(name: "Duplicate", startPositionTicks: 600 * t),
            JfChapter(name: "Past the end", startPositionTicks: 9_000 * t),
            JfChapter(name: "No start"),
            JfChapter(name: "Negative", startPositionTicks: -5),
        ], runTimeTicks: 7_200 * t)
        #expect(list == [Chapter(startSeconds: 0, name: "Chapter 1"), Chapter(startSeconds: 600, name: "Middle")])
    }

    @Test func oneChapterOrNoneOffersNothing() {
        #expect(Chapters.list([JfChapter(name: "Film", startPositionTicks: 0)]).isEmpty)
        #expect(Chapters.list(nil).isEmpty)
        #expect(Chapters.list([]).isEmpty)
        #expect(Chapters.list([JfChapter(name: "A", startPositionTicks: 0), JfChapter(name: "B", startPositionTicks: 100 * t)],
                              runTimeTicks: 50 * t).isEmpty, "the second is past the end, leaving one")
    }

    @Test func aMissingRuntimeKeepsEverything() {
        let list = Chapters.list([JfChapter(name: "A", startPositionTicks: 0), JfChapter(name: "B", startPositionTicks: 99_999 * t)])
        #expect(list.count == 2)
        #expect(Chapters.list([JfChapter(name: "A", startPositionTicks: 0), JfChapter(name: "B", startPositionTicks: 5 * t)],
                              runTimeTicks: 0).count == 2, "a zero runtime means unknown")
    }

    @Test func blankNamesGetTheirPosition() {
        let list = Chapters.list([JfChapter(name: "  ", startPositionTicks: 0), JfChapter(name: nil, startPositionTicks: 60 * t),
                                  JfChapter(name: " Named ", startPositionTicks: 120 * t)])
        #expect(list.map(\.name) == ["Chapter 1", "Chapter 2", "Named"])
    }

    @Test func aTranscodeStartedPartwayDropsEarlierChaptersAndShiftsTheRest() {
        let all = [Chapter(startSeconds: 0, name: "a"), Chapter(startSeconds: 60, name: "b"), Chapter(startSeconds: 120, name: "c")]
        #expect(Chapters.onPlayerTimeline(all, streamStartSeconds: 0) == all)
        #expect(Chapters.onPlayerTimeline(all, streamStartSeconds: 60) == [Chapter(startSeconds: 0, name: "b"), Chapter(startSeconds: 60, name: "c")])
        #expect(Chapters.onPlayerTimeline(all, streamStartSeconds: 500).isEmpty)
    }

    @Test func decodesJellyfinsChaptersField() throws {
        let json = #"{"Chapters":[{"Name":"Opening","StartPositionTicks":0,"ImageTag":"x"},{"Name":"Title","StartPositionTicks":900000000}]}"#
        struct Response: Decodable { var chapters: [JfChapter]? }
        let r = try JSON.decoder.decode(Response.self, from: Data(json.utf8))
        #expect(Chapters.list(r.chapters).map(\.name) == ["Opening", "Title"])
    }
}

@Suite("Chapter jumps")
struct ChapterJumpTests {
    private let c = [Chapter(startSeconds: 0, name: "a"), Chapter(startSeconds: 60, name: "b"), Chapter(startSeconds: 120, name: "c")]

    @Test func forwardGoesToTheNextStart() {
        #expect(Chapters.jumpTarget(in: c, from: 30, forward: true) == 60)
        #expect(Chapters.jumpTarget(in: c, from: 130, forward: true) == nil)
    }

    @Test func backRestartsTheChapterOrGoesToThePreviousOne() {
        #expect(Chapters.jumpTarget(in: c, from: 90, forward: false) == 60)
        #expect(Chapters.jumpTarget(in: c, from: 61, forward: false) == 0)
        #expect(Chapters.jumpTarget(in: c, from: 1, forward: false) == 0)
    }
}
