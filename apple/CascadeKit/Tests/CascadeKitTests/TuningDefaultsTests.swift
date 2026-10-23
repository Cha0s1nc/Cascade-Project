import XCTest
@testable import CascadeKit

final class TuningDefaultsTests: XCTestCase {
    /// The compiled-in copy, for every platform: it parses, and the values the
    /// apps were tuned to before the file existed come out of it unchanged.
    func testCompiledFileResolvesPerPlatform() throws {
        let data = Data(TuningDefaultsData.json.utf8)
        let ios = try TuningDefaults(json: data, platform: .ios)
        let mac = try TuningDefaults(json: data, platform: .mac)
        let tv = try TuningDefaults(json: data, platform: .tvos)
        let desktop = try TuningDefaults(json: data, platform: .desktop)

        XCTAssertEqual(ios.style["lyricsDelay"], -0.35)
        XCTAssertEqual(mac.style["lyricsDelay"], -0.05)
        XCTAssertEqual(tv.style["lyricSize"], 44)
        XCTAssertEqual(mac.style["lyricSize"], 30)
        XCTAssertNil(desktop.style["lyricSize"])
        XCTAssertEqual(mac.style["currentLinePosition"], 0.12)
        XCTAssertEqual(desktop.style["currentLinePosition"], 0.5)
        XCTAssertNil(mac.style["lyricSpringStiffness"], "motion is not style")

        XCTAssertGreaterThanOrEqual(ios.revision, 3)
        XCTAssertEqual(ios.revisionKeys[3], ["lyricsDelay"])
        XCTAssertEqual(mac.revisionKeys[3], [])
        XCTAssertEqual(mac.revisionKeys[2]?.count, 8)

        XCTAssertEqual(mac.albumColors.clusters, 5)
        XCTAssertEqual(mac.albumColors.slots.count, 3)
        XCTAssertEqual(mac.albumColors.slots[0], .init(x: 78, y: 16, w: 78, h: 78, alpha: 0.88))
    }

    func testSplitValuesTakeTheMostSpecificTarget() throws {
        let json = #"""
        {"style": {"a": {"all": 1, "apple": 2, "tvos": 3, "note": "why"}, "b": 5, "c": {"desktop": 7}},
         "albumColors": {"clusters": 5, "iterations": 12, "minSeparation": 0.12, "minSampleL": 0.08, "maxSampleL": 0.97,
          "minShare": 0.01, "chromaPower": 1.5, "minL": {"all": 0.45, "ios": 0.5}, "maxL": 0.82, "minLLight": 0, "maxLLight": 0.27,
          "minChroma": 0.06, "lightAlphaScale": 1, "driftScale": 1, "frameMs": 66, "sampleSide": 80,
          "slots": [{"x": 1, "y": 2, "w": 3, "h": 4, "alpha": 0.5}]},
         "revisions": {"4": {"apple": ["a"], "desktop": ["c"]}}}
        """#
        let ios = try TuningDefaults(json: Data(json.utf8), platform: .ios)
        let tv = try TuningDefaults(json: Data(json.utf8), platform: .tvos)
        XCTAssertEqual(ios.style, ["a": 2, "b": 5])
        XCTAssertEqual(tv.style["a"], 3)
        XCTAssertEqual(ios.albumColors.minL, 0.5)
        XCTAssertEqual(tv.albumColors.minL, 0.45)
        XCTAssertEqual(ios.revision, 4)
        XCTAssertEqual(ios.revisionKeys[4], ["a"])
    }

    func testABrokenAlbumColorsSectionIsAnError() {
        let json = #"{"style": {}, "albumColors": {"clusters": "five"}, "revisions": {}}"#
        XCTAssertThrowsError(try TuningDefaults(json: Data(json.utf8), platform: .mac))
    }
}
