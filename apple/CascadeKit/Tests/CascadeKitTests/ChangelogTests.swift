import Foundation
import Testing
@testable import CascadeKit

// Ports test/changelog.test.ts (the parts the updater uses).
@Suite struct ChangelogTests {
    private let sample = """
    # Changelog

    Intro text, ignored. It may mention ## 1.0.0 (2020-01-01) inline.

    ## 2.3.0 (2026-10-05)
    ### Desktop
    - Reads versions.json
      - nested

    #### Fixes
    - A fix

    ### Apple
    - First iOS build

    ## 2.2.0 (2026-09-27)

    ### Android

    - Hello

    ### Desktop
    - Jellyfin 12
    """

    private func failure(_ md: String) -> Changelog.ParseError? {
        do { _ = try Changelog.parse(md); return nil } catch let e as Changelog.ParseError { return e } catch { return nil }
    }

    private func expectFailure(_ md: String, line: Int, _ fragment: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let e = failure(md) else { Issue.record("expected a ParseError", sourceLocation: sourceLocation); return }
        #expect(e.line == line, "\(e)", sourceLocation: sourceLocation)
        #expect(e.message.contains(fragment), "\(e)", sourceLocation: sourceLocation)
    }

    @Test func versionsAndPlatformSectionsBecomeData() throws {
        let entries = try Changelog.parse(sample)
        #expect(entries == [
            .init(version: "2.3.0", date: "2026-10-05", platforms: [
                .desktop: "- Reads versions.json\n  - nested\n\n#### Fixes\n- A fix",
                .apple: "- First iOS build",
            ]),
            .init(version: "2.2.0", date: "2026-09-27", platforms: [.android: "- Hello", .desktop: "- Jellyfin 12"]),
        ])
    }

    @Test func macSectionsParseLikeTheOthers() throws {
        let entries = try Changelog.parse("## 2.4.0 (2026-10-10)\n### Desktop\n- d\n### Mac\n- native\n")
        #expect(entries[0].platforms[.mac] == "- native")
    }

    @Test func windowsLineEndingsAndEmptyFiles() throws {
        #expect(try Changelog.parse(sample.replacingOccurrences(of: "\n", with: "\r\n"))[0].platforms[.apple] == "- First iOS build")
        #expect(try Changelog.parse("").isEmpty)
        #expect(try Changelog.parse("# Changelog\n\nNothing yet.\n").isEmpty)
    }

    @Test func headingsInsideACodeBlockAreText() throws {
        let md = "## 1.0.0 (2026-01-01)\n### Desktop\n```md\n## not a version\n### Nope\n```\n- after\n"
        #expect(try Changelog.parse(md)[0].platforms[.desktop] == "```md\n## not a version\n### Nope\n```\n- after")
        expectFailure("## 1.0.0 (2026-01-01)\n### Desktop\n```\nopen\n", line: 3, "never closed")
    }

    @Test func malformedVersionHeadingsAreRefused() {
        let bad = ["## 2.3.0", "## v2.3.0 (2026-10-05)", "## 2.3 (2026-10-05)", "## 2.3.0 2026-10-05", "## 2.3.0 (2026-10-5)",
                   "## 2.3.0-b1 (2026-10-05)", "## 02.3.0 (2026-10-05)", "## Unreleased", "##", "## 2.3.0  (2026-10-05)"]
        for heading in bad { expectFailure("# Changelog\n\n\(heading)\n### Desktop\n- x\n", line: 3, "version heading") }
    }

    @Test func datesThatDoNotExistAreRefused() {
        expectFailure("## 2.3.0 (2026-02-30)\n### Desktop\n- x\n", line: 1, "not a real date")
        expectFailure("## 2.3.0 (2026-13-01)\n### Desktop\n- x\n", line: 1, "not a real date")
    }

    @Test func unknownOrMisplacedPlatformHeadingsAreRefused() {
        expectFailure("## 2.3.0 (2026-10-05)\n### Windows\n- x\n", line: 2, "Desktop")
        expectFailure("## 2.3.0 (2026-10-05)\n### desktop\n- x\n", line: 2, "Desktop")
        expectFailure("### Desktop\n- x\n## 2.3.0 (2026-10-05)\n", line: 1, "before any version")
        expectFailure("## 2.3.0 (2026-10-05)\n### Desktop\n- x\n### Desktop\n- y\n", line: 4, "two Desktop sections")
        expectFailure("## 2.3.0 (2026-10-05)\n### Desktop\n- x\n### Apple\n- a\n### Desktop\n- y\n", line: 6, "two Desktop sections")
    }

    @Test func textOutsideAPlatformSectionIsRefused() {
        expectFailure("## 2.3.0 (2026-10-05)\nLoose text\n### Desktop\n- x\n", line: 2, "before its first")
        expectFailure("## 2.3.0 (2026-10-05)\n### Desktop\n- x\n# Title\n", line: 4, "use ####")
    }

    @Test func anEmptySectionOrAVersionWithNoneIsRefused() {
        expectFailure("## 2.3.0 (2026-10-05)\n### Desktop\n\n### Apple\n- a\n", line: 2, "Desktop section of 2.3.0 is empty")
        expectFailure("## 2.3.0 (2026-10-05)\n\n## 2.2.0 (2026-09-27)\n### Desktop\n- x\n", line: 1, "no ### Desktop")
        expectFailure("## 2.3.0 (2026-10-05)\n", line: 1, "no ### Desktop")
    }

    @Test func duplicatesAndVersionsOutOfOrderAreRefused() {
        func v(_ s: String) -> String { "## \(s)\n### Desktop\n- x\n" }
        expectFailure(v("2.3.0 (2026-10-05)") + v("2.3.0 (2026-10-06)"), line: 4, "listed twice")
        expectFailure(v("2.2.0 (2026-09-27)") + v("2.3.0 (2026-10-05)"), line: 4, "newest first")
        expectFailure(v("2.9.0 (2026-09-27)") + v("2.10.0 (2026-10-05)"), line: 4, "newest first")
    }

    @Test func findIgnoresALeadingV() throws {
        let entries = try Changelog.parse(sample)
        #expect(Changelog.find(entries, version: "2.2.0")?.date == "2026-09-27")
        #expect(Changelog.find(entries, version: "v2.3.0")?.date == "2026-10-05")
        #expect(Changelog.find(entries, version: "2.1.0") == nil)
    }

    @Test func theRealChangelogParsesNewestFirst() throws {
        // CHANGELOG.md at the repo root, found from this file. Skipped quietly
        // if the tests run somewhere the repo is not around them.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        guard let text = try? String(contentsOf: url.appending(path: "CHANGELOG.md"), encoding: .utf8) else { return }
        let entries = try Changelog.parse(text)
        for v in ["2.2.0", "2.1.0", "2.0.1", "2.0.0"] {
            #expect(Changelog.find(entries, version: v)?.platforms[.desktop] != nil, "\(v)")
        }
    }

    @Test func jsonRoundTripsAndRefusesAnythingMalformed() {
        func data(_ s: String) -> Data { Data(s.utf8) }
        let ok = #"{"version":"2.3.0","date":"2026-10-05","platforms":{"desktop":"- x"}}"#
        #expect(Changelog.fromJSON(data("[\(ok)]")) == [.init(version: "2.3.0", date: "2026-10-05", platforms: [.desktop: "- x"])])
        // Unknown platforms are ignored, not an error.
        #expect(Changelog.fromJSON(data(#"[{"version":"2.3.0","date":"2026-10-05","platforms":{"desktop":"- x","web":"- ignored"}}]"#))?.count == 1)
        let long = String(repeating: "x", count: 20_001)
        let bad = ["null", "{}", #""text""#, "[null]",
                   #"[{"version":"v2.3.0","date":"2026-10-05","platforms":{"desktop":"- x"}}]"#,
                   #"[{"version":"2.3.0-b1","date":"2026-10-05","platforms":{"desktop":"- x"}}]"#,
                   #"[{"version":"2.3.0","date":"2026-02-30","platforms":{"desktop":"- x"}}]"#,
                   #"[{"version":"2.3.0","date":"2026-10-05","platforms":[]}]"#,
                   #"[{"version":"2.3.0","date":"2026-10-05","platforms":{"desktop":5}}]"#,
                   #"[{"version":"2.3.0","date":"2026-10-05","platforms":{"desktop":" "}}]"#,
                   #"[{"version":"2.3.0","date":"2026-10-05","platforms":{"desktop":"\#(long)"}}]"#,
                   "[" + Array(repeating: ok, count: 501).joined(separator: ",") + "]"]
        for b in bad { #expect(Changelog.fromJSON(data(b)) == nil, "\(b.prefix(80))") }
    }

    @Test func notesBetweenListsOnePlatformAfterCurrentUpToTargetNewestFirst() {
        func e(_ version: String, _ platforms: [Changelog.Platform: String]) -> Changelog.Entry {
            .init(version: version, date: "2026-10-01", platforms: platforms)
        }
        let entries = [e("2.3.2", [.apple: "- a"]), e("2.3.1", [.desktop: "- d1"]), e("2.3.0", [.desktop: "- d0"]),
                       e("2.2.0", [.desktop: "- old"]), e("2.4.0", [.desktop: "- future"])]
        #expect(Changelog.notesBetween(entries, platform: .desktop, current: "2.2.0", target: "2.3.2")
                == "## 2.3.1 (2026-10-01)\n\n- d1\n\n## 2.3.0 (2026-10-01)\n\n- d0")
        #expect(Changelog.notesBetween(entries, platform: .desktop, current: "2.3.1", target: "2.3.2") == "")
        // A copy that does not know the target yet is stale, not empty.
        #expect(Changelog.notesBetween(entries, platform: .desktop, current: "2.2.0", target: "2.3.3") == nil)
        // A beta of the target's base counts as older than it.
        #expect(Changelog.notesBetween(entries, platform: .desktop, current: "2.3.0-b2", target: "2.3.0")?.hasPrefix("## 2.3.0 ") == true)
        // The native build reads its own platform's sections.
        let mac = [e("2.4.0", [.mac: "- native", .desktop: "- d"])]
        #expect(Changelog.notesBetween(mac, platform: .mac, current: "2.3.0", target: "2.4.0") == "## 2.4.0 (2026-10-01)\n\n- native")
    }
}
