import Foundation
import Testing
@testable import CascadeKit

// Ports test/release-notes.test.ts. The desktop checks HTML strings; this
// checks the blocks and the text attributes the SwiftUI view draws from.
@Suite struct ReleaseNotesTests {
    private func plain(_ a: AttributedString) -> String { String(a.characters) }

    private func intents(_ a: AttributedString) -> [(String, InlinePresentationIntent)] {
        a.runs.compactMap { run in a[run.range].inlinePresentationIntent.map { (String(a[run.range].characters), $0) } }
    }

    @Test func tabIndentedBulletsNestUnderTheirParent() throws {
        let blocks = ReleaseNotes.parse("- Added Jellyfin 12 support\r\n\t- Older versions will *not* connect\r\n- Karaoke lyrics")
        #expect(blocks.count == 1)
        guard case .list(let ordered, let items) = try #require(blocks.first) else { Issue.record("not a list"); return }
        #expect(!ordered)
        #expect(items.map { plain($0.text) } == ["Added Jellyfin 12 support", "Karaoke lyrics"])
        guard case .list(_, let nested) = try #require(items[0].children.first) else { Issue.record("no nested list"); return }
        #expect(plain(nested[0].text) == "Older versions will not connect")
        #expect(intents(nested[0].text).map(\.0) == ["not"])
        #expect(intents(nested[0].text).first?.1 == .emphasized)
    }

    @Test func emphasisTheTwoTwoZeroNotesUse() {
        let a = ReleaseNotes.inline("Spicy Lyrics is ***ONLY*** with **the** plugin")
        #expect(plain(a) == "Spicy Lyrics is ONLY with the plugin")
        #expect(intents(a).map(\.0) == ["ONLY", "the"])
        #expect(intents(a)[0].1 == [.stronglyEmphasized, .emphasized])
        #expect(intents(a)[1].1 == .stronglyEmphasized)
        let b = ReleaseNotes.inline("Use `npm test` and ~~old~~ new")
        #expect(plain(b) == "Use npm test and old new")
        #expect(intents(b).map(\.1) == [.code, .strikethrough])
    }

    @Test func codeSpansAreNotEmphasised() {
        let a = ReleaseNotes.inline("run `a*b*c` now")
        #expect(plain(a) == "run a*b*c now")
        #expect(intents(a).map(\.1) == [.code])
    }

    @Test func onlyHttpUrlsBecomeLinks() {
        let a = ReleaseNotes.inline("[CascadeServer](https://github.com/Cha0s1nc/CascadeServer_x_)")
        #expect(plain(a) == "CascadeServer")
        #expect(a.runs.first?.link?.absoluteString == "https://github.com/Cha0s1nc/CascadeServer_x_")
        // A URL's own underscores are not emphasis.
        #expect(intents(a).isEmpty)
        let hostile = ReleaseNotes.inline("[x](javascript:alert(1)) <img src=x onerror=alert(1)>")
        #expect(hostile.runs.allSatisfy { $0.link == nil })
        let bare = ReleaseNotes.inline("see https://example.com/a_b_c now")
        #expect(bare.runs.contains { $0.link?.absoluteString == "https://example.com/a_b_c" })
    }

    @Test func intrawordUnderscoresStayPlain() {
        #expect(intents(ReleaseNotes.inline("snake_case_name stays")).isEmpty)
        #expect(intents(ReleaseNotes.inline("this is _fine_ though")).map(\.1) == [.emphasized])
    }

    @Test func headingsRulesAndAnEmptyBody() {
        let blocks = ReleaseNotes.parse("## Major changes\n\n---\nDone")
        #expect(blocks.count == 3)
        if case .heading(let level, let text) = blocks[0] { #expect(level == 2); #expect(plain(text) == "Major changes") } else { Issue.record("heading") }
        #expect(blocks[1] == .rule)
        if case .paragraph(let text) = blocks[2] { #expect(plain(text) == "Done") } else { Issue.record("paragraph") }
        #expect(ReleaseNotes.parse("").isEmpty)
    }

    @Test func wrappedLinesJoin() {
        let p = ReleaseNotes.parse("The updater cannot\ninstall updates.\n\nNext one")
        #expect(p.count == 2)
        if case .paragraph(let t) = p[0] { #expect(plain(t) == "The updater cannot install updates.") } else { Issue.record("p0") }

        let l = ReleaseNotes.parse("- Only through the plugin\n  (renamed). Server owners\n- Two")
        if case .list(_, let items) = l[0] {
            #expect(items.map { plain($0.text) } == ["Only through the plugin (renamed). Server owners", "Two"])
        } else { Issue.record("list") }

        let mixed = ReleaseNotes.parse("Intro\n### Desktop\n- a")
        #expect(mixed.count == 3)
        if case .heading(let level, _) = mixed[1] { #expect(level == 3) } else { Issue.record("heading") }
    }

    @Test func orderedListsAreMarkedAsSuch() {
        if case .list(let ordered, let items) = ReleaseNotes.parse("1. one\n2. two")[0] {
            #expect(ordered)
            #expect(items.count == 2)
        } else { Issue.record("list") }
    }
}
