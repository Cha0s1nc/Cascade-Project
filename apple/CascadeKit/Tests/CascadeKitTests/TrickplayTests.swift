import Foundation
import Testing
@testable import CascadeKit

struct TrickplayTests {
    /// 320x180 frames, 10 across by 10 down, one every 10 s, 250 of them: two
    /// full sheets and half a third.
    private let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 250, interval: 10_000)
    private var trick: Trickplay { Trickplay(frameWidth: 320, info: info) }

    @Test func framesWalkTheGridThenTheNextSheet() {
        #expect(trick.frame(atSeconds: 0) == TrickplayFrame(sheet: 0, x: 0, y: 0, width: 320, height: 180))
        #expect(trick.frame(atSeconds: 9.9) == TrickplayFrame(sheet: 0, x: 0, y: 0, width: 320, height: 180))
        #expect(trick.frame(atSeconds: 10) == TrickplayFrame(sheet: 0, x: 320, y: 0, width: 320, height: 180))
        #expect(trick.frame(atSeconds: 125) == TrickplayFrame(sheet: 0, x: 640, y: 180, width: 320, height: 180), "frame 12: row 1, column 2")
        #expect(trick.frame(atSeconds: 1_000) == TrickplayFrame(sheet: 1, x: 0, y: 0, width: 320, height: 180), "frame 100 opens sheet 1")
    }

    @Test func pastTheEndIsTheLastFrameInThePartlyFilledSheet() {
        // Frame 249: sheet 2, position 49, row 4, column 9.
        let last = TrickplayFrame(sheet: 2, x: 9 * 320, y: 4 * 180, width: 320, height: 180)
        #expect(trick.frame(atSeconds: 2_490) == last)
        #expect(trick.frame(atSeconds: 99_999) == last)
        #expect(trick.frame(atSeconds: -5)?.sheet == 0)
        #expect(trick.frame(atSeconds: .nan) == nil)
    }

    @Test func aManifestWithZerosDrawsNothing() {
        var broken = info
        broken.interval = 0
        #expect(Trickplay(frameWidth: 320, info: broken).frame(atSeconds: 5) == nil)
        #expect(Trickplay.pick(["src": ["320": broken]], mediaSourceId: "src") == nil)
        #expect(Trickplay.pick(nil, mediaSourceId: "src") == nil)
        #expect(Trickplay.pick([:], mediaSourceId: "src") == nil)
    }

    @Test func picksTheSourceAndASensibleWidth() {
        var small = info; small.width = 160
        var big = info; big.width = 640
        let manifest = ["a1b2": ["160": small, "320": info, "640": big], "c3d4": ["160": small]]
        #expect(Trickplay.pick(manifest, mediaSourceId: "a1b2")?.frameWidth == 320)
        #expect(Trickplay.pick(manifest, mediaSourceId: "A1B2")?.frameWidth == 320, "the key went through the case rule")
        #expect(Trickplay.pick(manifest, mediaSourceId: "c3d4")?.frameWidth == 160, "only smaller widths: take the largest")
        #expect(Trickplay.pick(manifest, mediaSourceId: "zzzz") == nil, "two sources and no match: guessing would show another cut")
        #expect(Trickplay.pick(["only": ["320": info]], mediaSourceId: nil)?.frameWidth == 320, "one source is that source")
    }

    @Test func theServersManifestSurvivesTheJSONCaseRule() throws {
        let body = #"{"Trickplay":{"6f1d0c2e9a7b4e1c8d3a5b6c7d8e9f01":{"320":{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":711,"Interval":10000,"Bandwidth":24350}}}}"#
        struct Response: Decodable { var trickplay: [String: [String: TrickplayInfo]]? }
        let r = try JSON.decoder.decode(Response.self, from: Data(body.utf8))
        let picked = Trickplay.pick(r.trickplay, mediaSourceId: "6f1d0c2e9a7b4e1c8d3a5b6c7d8e9f01")
        #expect(picked?.frameWidth == 320)
        #expect(picked?.info.thumbnailCount == 711)
    }

    @Test func chapterAtAPositionAndTicks() {
        let list = [Chapter(startSeconds: 0, name: "One"), Chapter(startSeconds: 300, name: "Two"), Chapter(startSeconds: 900, name: "Three")]
        #expect(Chapters.current(in: list, at: 0)?.name == "One")
        #expect(Chapters.current(in: list, at: 299.9)?.name == "One")
        #expect(Chapters.current(in: list, at: 300)?.name == "Two")
        #expect(Chapters.current(in: list, at: 5_000)?.name == "Three")
        #expect(Chapters.current(in: [Chapter(startSeconds: 60, name: "Late")], at: 10) == nil)
        #expect(Chapters.tickFractions(list, duration: 1_200) == [0.25, 0.75])
        #expect(Chapters.tickFractions(list, duration: 0).isEmpty)
        #expect(Chapters.tickFractions(list, duration: .nan).isEmpty)
    }
}
