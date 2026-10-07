import Foundation
import Testing
@testable import CascadeKit

// Ported from the desktop's test/presets.test.ts: the same file format, so a
// look exported on one app imports on the other.
@Suite("Cascade presets")
struct PresetTests {
    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func aPresetSurvivesExportAndImport() throws {
        let preset = CascadePreset(
            name: "Sunset",
            theme: .init(mode: .light, gradStart: "#f97316", gradEnd: "#ec4899", albumArt: true,
                         bgDim: 0.3, bgBlend: false, fontPreset: "serif", fontCustom: ""),
            lyrics: .init(style: ["pastBlur": 1.5, "heldScale": 1.12], lyricScale: 1.2))
        #expect(try CascadePreset.parse(preset.serialized()).get() == preset)
    }

    @Test func oneSidedPresetsCarryOnlyThatPart() throws {
        let lyricsOnly = try CascadePreset.parse(json(["format": "cascade-preset", "version": 1, "lyrics": [:]])).get()
        #expect(lyricsOnly.theme == nil && lyricsOnly.lyrics != nil)
        let themeOnly = try CascadePreset.parse(json(["format": "cascade-preset", "version": 1, "theme": [:]])).get()
        #expect(themeOnly.lyrics == nil && themeOnly.theme != nil)
    }

    @Test func badValuesTakeTheShippedDefault() throws {
        let text = json([
            "format": "cascade-preset", "version": 1, "name": "Bad",
            "theme": ["mode": "neon", "gradStart": "red; background: url(x)", "gradEnd": "#12345", "albumArt": "yes",
                      "bgDim": "NaN", "bgBlend": "no", "font": ["preset": "custom", "custom": "Evil\"; } body { x"]],
            "lyrics": ["style": ["pastBlur": 9999, "lineGap": "wide", "../x": 3, "flag": true], "lyricScale": 99],
        ])
        let p = try CascadePreset.parse(text).get()
        let t = try #require(p.theme)
        #expect(t.mode == .dark)
        #expect(t.gradStart == CascadePreset.defaultGradient.start)
        #expect(t.gradEnd == CascadePreset.defaultGradient.end)
        #expect(t.albumArt == false)
        #expect(t.bgDim == NPTuning.bgDimDefault)
        #expect(t.bgBlend == true)
        #expect(t.fontPreset == "custom")
        #expect(t.fontCustom == AppFont.sanitize("Evil\"; } body { x"))
        // Numbers pass (the app clamps each to its knob's range); text, booleans
        // and keys that are not identifiers do not.
        #expect(p.lyrics?.style == ["pastBlur": 9999])
        #expect(p.lyrics?.lyricScale == NPTuning.lyricScaleRange.upperBound)
    }

    @Test func anUnknownFontFallsBackToSystem() throws {
        let p = try CascadePreset.parse(json(["format": "cascade-preset", "version": 1,
                                              "theme": ["font": ["preset": "comic", "custom": "x"]]])).get()
        #expect(p.theme?.fontPreset == "system")
        #expect(p.theme?.fontCustom == "")
    }

    @Test func anythingElseIsRefusedWithAReason() {
        let cases = ["", "   ", "not json", "[]", "{}", "42",
                     json(["format": "something-else", "version": 1, "theme": [:]]),
                     json(["format": "cascade-preset", "theme": [:]]),
                     json(["format": "cascade-preset", "version": 1.5, "theme": [:]]),
                     json(["format": "cascade-preset", "version": 1]),
                     json(["format": "cascade-preset", "version": 1, "theme": "dark"])]
        for text in cases {
            guard case .failure(let error) = CascadePreset.parse(text) else {
                Issue.record("accepted \(text)")
                continue
            }
            #expect(!error.description.isEmpty)
        }
    }

    @Test func aNewerPresetSaysToUpdate() {
        #expect(CascadePreset.parse(json(["format": "cascade-preset", "version": 2, "theme": [:]])) == .failure(.newer))
    }

    @Test func oversizedInputIsRefused() {
        let text = String(repeating: " ", count: CascadePreset.maxBytes + 1) + "{}"
        #expect(CascadePreset.parse(text) == .failure(.tooLarge))
    }

    @Test func namesAreCleanedAndFileNamesAreSafe() throws {
        let p = try CascadePreset.parse(json(["format": "cascade-preset", "version": 1, "name": "  My\u{07} look  ", "theme": [:]])).get()
        #expect(p.name == "My look")
        #expect(CascadePreset.cleanName(42) == "Untitled")
        #expect(CascadePreset.fileName("a/b:c*?") == "a-b-c-.cascadepreset")
        #expect(CascadePreset.fileName("...") == "Cascade preset.cascadepreset")
    }

    @Test func aDesktopExportReads() throws {
        // As the desktop's serializePreset writes it.
        let desktop = """
        {
          "format": "cascade-preset",
          "version": 1,
          "name": "Sunset",
          "theme": { "mode": "dark", "gradStart": "#f97316", "gradEnd": "#ec4899", "albumArt": false, "bgDim": 0.16, "bgBlend": true, "font": { "preset": "system", "custom": "" } },
          "lyrics": { "style": { "pastBlur": 1.5 }, "lyricScale": 1 }
        }
        """
        let p = try CascadePreset.parse(desktop).get()
        #expect(p.name == "Sunset")
        #expect(p.theme?.gradEnd == "#ec4899")
        #expect(p.lyrics?.style == ["pastBlur": 1.5])
        #expect(p.lyrics?.lyricScale == 1)
    }
}
