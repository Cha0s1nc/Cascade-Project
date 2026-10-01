import Foundation
import Testing
@testable import CascadeKit

struct MediaSegmentsTests {
    private let t = 10_000_000.0

    private func body(_ items: String) -> Data {
        Data(#"{"Items":[\#(items)],"TotalRecordCount":1,"StartIndex":0}"#.utf8)
    }

    private func seg(_ type: MediaSegmentType, _ start: Double, _ end: Double) -> MediaSegment {
        MediaSegment(type: type, startSeconds: start, endSeconds: end)
    }

    @Test func parsesAResponseAndConvertsTicksToSeconds() {
        let data = body("""
        {"Id":"b","ItemId":"x","Type":"Outro","StartTicks":12000000000,"EndTicks":13000000000},
        {"Id":"a","ItemId":"x","Type":"Intro","StartTicks":300000000,"EndTicks":900000000}
        """)
        #expect(MediaSegments.parse(data) == [seg(.intro, 30, 90), seg(.outro, 1200, 1300)])
    }

    @Test func anEmptyOrUnexpectedBodyIsNoSegments() {
        #expect(MediaSegments.parse(body("")) == [])
        #expect(MediaSegments.parse(Data("{}".utf8)) == [])
        #expect(MediaSegments.parse(Data("not json".utf8)) == [])
        #expect(MediaSegments.parse(Data()) == [])
    }

    @Test func dropsUnknownTypesAndMalformedRanges() {
        let data = body("""
        {"Type":"Unknown","StartTicks":0,"EndTicks":50000000},
        {"Type":"Bogus","StartTicks":0,"EndTicks":50000000},
        {"Type":"Intro","StartTicks":-1,"EndTicks":50000000},
        {"Type":"Intro","StartTicks":50000000,"EndTicks":50000000},
        {"Type":"Intro","StartTicks":90000000,"EndTicks":50000000},
        {"Type":"Intro","StartTicks":0},
        {"StartTicks":0,"EndTicks":50000000},
        {"Type":"Recap","StartTicks":0,"EndTicks":50000000}
        """)
        #expect(MediaSegments.parse(data) == [seg(.recap, 0, 5)])
    }

    @Test func startIsInsideAndEndIsOutside() {
        let list = [seg(.intro, 30, 90)]
        #expect(MediaSegments.active(in: list, at: 29.999) == nil)
        #expect(MediaSegments.active(in: list, at: 30)?.type == .intro)
        #expect(MediaSegments.active(in: list, at: 89.999)?.type == .intro)
        #expect(MediaSegments.active(in: list, at: 90) == nil)
    }

    @Test func noSegmentsAndJunkPositionsAreNil() {
        #expect(MediaSegments.active(in: [], at: 10) == nil)
        #expect(MediaSegments.active(in: [seg(.intro, 0, 10)], at: .nan) == nil)
        #expect(MediaSegments.active(in: [seg(.intro, 0, 10)], at: .infinity) == nil)
    }

    @Test func onlyIntrosAndOutrosAreOffered() {
        let list = [seg(.recap, 0, 60), seg(.preview, 100, 120), seg(.commercial, 200, 260)]
        for at in [10.0, 110, 220] { #expect(MediaSegments.active(in: list, at: at) == nil) }
    }

    @Test func overlappingSegmentsTheOneThatEndsLastWins() {
        let list = [seg(.intro, 30, 80), seg(.intro, 40, 100), seg(.recap, 0, 500)]
        #expect(MediaSegments.active(in: list, at: 50)?.endSeconds == 100)
        #expect(MediaSegments.active(in: list, at: 35)?.endSeconds == 80)
    }

    @Test func labelsNameTheSegment() {
        #expect(seg(.intro, 0, 1).skipLabel == "Skip Intro")
        #expect(seg(.outro, 0, 1).skipLabel == "Skip Credits")
    }

    @Test func skippingAnIntroSeeksToItsEnd() {
        #expect(MediaSegments.skipAction(for: seg(.intro, 30, 90), duration: 2600) == .seek(90))
        #expect(MediaSegments.skipAction(for: seg(.intro, 0, 90), duration: 90) == .seek(90))
    }

    @Test func anOutroThatRunsToTheEndGoesOn() {
        #expect(MediaSegments.skipAction(for: seg(.outro, 2400, 2500), duration: 2600) == .seek(2500))
        #expect(MediaSegments.skipAction(for: seg(.outro, 2400, 2600), duration: 2600) == .next)
        #expect(MediaSegments.skipAction(for: seg(.outro, 2400, 2599.5), duration: 2600) == .next)
        #expect(MediaSegments.skipAction(for: seg(.outro, 2400, 2700), duration: 2600) == .next)
        #expect(MediaSegments.skipAction(for: seg(.outro, 2400, 2600), duration: 0) == .seek(2600))
    }
}
