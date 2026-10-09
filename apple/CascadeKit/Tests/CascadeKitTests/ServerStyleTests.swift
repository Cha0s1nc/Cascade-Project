import Foundation
import Testing
@testable import CascadeKit

// The desktop's test/server-style.test.ts, for the same rules.
struct ServerStyleTests {
    private func style(_ object: [String: Any]) -> ServerStyle {
        ServerStyle.parse(try! JSONSerialization.data(withJSONObject: object))
    }
    private let preset: [String: Any] = [
        "format": "cascade-preset", "version": 1, "name": "House",
        "theme": ["mode": "light", "gradStart": "#111111", "gradEnd": "#222222", "albumArt": true, "bgDim": 0.5, "bgBlend": false],
        "lyrics": ["style": ["pastBlur": 3], "lyricScale": 1.2],
    ]

    @Test func anythingUnexpectedIsOff() {
        #expect(ServerStyle.parse(Data("x".utf8)) == .off)
        #expect(style([:]) == .off)
        #expect(style(["mode": "off", "preset": preset]) == .off)
        #expect(style(["mode": "default"]) == .off)
        #expect(style(["mode": "enforced", "preset": ["format": "nope"]]) == .off)
    }

    @Test func enforceFlagsCountOnlyWhenEnforced() {
        #expect(style(["mode": "default", "enforce": ["theme": true], "preset": preset]).themePart == .fill)
        let e = style(["mode": "enforced", "enforce": ["theme": true, "lyrics": false], "preset": preset])
        #expect(e.themePart == .force)
        #expect(e.lyricsPart == .fill)
    }

    @Test func defaultFillsOnlyWhatWasNeverSet() {
        let s = style(["mode": "default", "preset": preset])
        #expect(s.layeredLyricChanges(["pastBlur": 1, "lineGap": 9]) == ["pastBlur": 1, "lineGap": 9])
        #expect(s.layeredLyricChanges([:]) == ["pastBlur": 3])
        let fresh = s.layered(theme: ThemeSettings(), colorsSet: false, tuning: .init(), tuningSet: false)
        #expect(fresh.theme.gradStart == "#111111")
        #expect(fresh.theme.mode == .dark, "mode stays the person's")
        #expect(fresh.tuning.bgDim == 0.5)
        #expect(fresh.tuning.lyricScale == 1.2)
        let mine = s.layered(theme: ThemeSettings(), colorsSet: true, tuning: .init(), tuningSet: true)
        #expect(mine.theme == ThemeSettings())
        #expect(mine.tuning == NPTuning.Values())
    }

    @Test func enforcedIsOverTheirOwn() {
        let s = style(["mode": "enforced", "enforce": ["theme": true, "lyrics": true], "preset": preset])
        #expect(s.layeredLyricChanges(["pastBlur": 1, "lineGap": 9]) == ["pastBlur": 3])
        let look = s.layered(theme: ThemeSettings(), colorsSet: true, tuning: .init(), tuningSet: true)
        #expect(look.theme.gradEnd == "#222222")
        #expect(look.theme.albumArt)
        #expect(look.tuning.bgBlend == false)
    }

    @Test func colorsCountAsSetOnlyWhenChosen() {
        #expect(!ServerStyle.colorsSet(stored: nil))
        #expect(!ServerStyle.colorsSet(stored: #"{"mode":"light"}"#))
        #expect(ServerStyle.colorsSet(stored: ##"{"mode":"dark","gradStart":"#000000","gradEnd":"#ffffff"}"##))
        #expect(ServerStyle.colorsSet(stored: #"{"albumArt":true}"#))
    }
}
