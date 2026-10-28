import Foundation
import Testing
@testable import CascadeKit

@Suite struct ThemeModelTests {
    @Test func thereAreNinePresetsAndTheFirstIsTheDefaultTheme() {
        #expect(ThemePreset.all.count == 9)
        let s = ThemeSettings()
        #expect(s.activePreset?.label == "Default")
        #expect(s.mode == .dark && !s.albumArt)
        for p in ThemePreset.all { #expect(HexColor.isValid(p.start) && HexColor.isValid(p.end)) }
    }

    @Test func aStoredThemeRoundTrips() {
        var s = ThemeSettings()
        s.mode = .light
        s.gradStart = "#f97316"
        s.gradEnd = "#ec4899"
        s.albumArt = true
        #expect(ThemeSettings(stored: s.encoded()) == s)
        #expect(ThemeSettings(stored: s.encoded()).activePreset?.label == "Sunset")
    }

    @Test func aStoredThemeIsValidatedFieldByField() {
        // The mode survives a bad colour; a bad mode keeps the default.
        let bad = ThemeSettings(stored: ##"{"mode":"light","gradStart":"javascript:x","gradEnd":"#fff","albumArt":true}"##)
        #expect(bad.mode == .light && bad.albumArt)
        #expect(bad.gradStart == ThemeSettings().gradStart && bad.gradEnd == ThemeSettings().gradEnd)
        #expect(ThemeSettings(stored: #"{"mode":"sepia"}"#).mode == .dark)
        #expect(ThemeSettings(stored: "not json") == ThemeSettings())
        #expect(ThemeSettings(stored: nil) == ThemeSettings())
        #expect(ThemeSettings(stored: ##"{"gradStart":"#ABCDEF","gradEnd":"#123456"}"##).gradStart == "#abcdef")
    }

    @Test func hexParsingIsStrict() {
        #expect(HexColor.rgb("#4ade80")! == (0x4a, 0xde, 0x80))
        for bad in ["", "4ade80", "#4ade8", "#4ade800", "#gggggg", "#4ade8z"] { #expect(HexColor.rgb(bad) == nil, "\(bad)") }
        #expect(HexColor.string(r: 300, g: -4, b: 128) == "#ff0080")
    }

    @Test func aLightAccentGetsDarkInk() {
        #expect(HexColor.prefersDarkInk(over: "#fbbf24"))
        #expect(!HexColor.prefersDarkInk(over: "#7c3aed"))
        #expect(!HexColor.prefersDarkInk(over: "not a color"))
    }

    @Test func lightModeDarkensAPaleAccentToReadableAndLeavesADarkOneAlone() {
        // Waterfall blue is 1.7:1 on #f2f2f7; the old purple already passes. Same values as desktop.
        #expect(HexColor.readableOnLight("#7cc4ff") == "#2973a9")
        #expect(HexColor.readableOnLight("#7c3aed") == "#7c3aed")
        #expect(HexColor.readableOnLight("#ffffff") == "#6f6f6f")
        #expect(HexColor.readableOnLight("nope") == "nope")
    }

    /// A blob as extractTopColors makes it, raw chroma included.
    func blob(_ r: Double, _ g: Double, _ b: Double) -> BlobColor { AlbumColors.blobColor(AlbumColors.oklab(r: r, g: g, b: b)) }

    @Test func aSaturatedCoverGivesAVividAccentOfItsHue() {
        let art = ArtTheme(from: [blob(200, 40, 50), blob(30, 30, 200)])
        #expect(art.blobs.count == 2)
        let start = HexColor.rgb(art.start)!, end = HexColor.rgb(art.end)!
        // Red-dominant, brighter at the start than the end.
        #expect(start.r > start.g && start.r > start.b && end.r > end.g && end.r > end.b)
        #expect(HexColor.luminance(art.start) > HexColor.luminance(art.end))
    }

    @Test func jpegNoiseOnABlackAndWhiteCoverIsNotAColour() {
        // minChroma lifts a faintly warm grey to a visible colour; the accent must look past it.
        let art = ArtTheme(from: [blob(120, 118, 116), blob(60, 59, 58)])
        #expect(art.start == "#505050" && art.end == "#202020")
    }

    @Test func aGreyFieldRankedFirstDoesNotHideTheColourBesideIt() {
        let art = ArtTheme(from: [blob(120, 120, 119), blob(60, 160, 90)])
        let start = HexColor.rgb(art.start)!
        #expect(start.g > start.r && start.g > start.b)
    }

    @Test func aMonochromeCoverGivesGreyAndNeverInventsAHue() {
        let art = ArtTheme(from: [BlobColor(r: 120, g: 120, b: 124, hue: 0)])
        #expect(art.start == "#505050" && art.end == "#202020")
        #expect(art.blobs.count == 2 && art.blobs.allSatisfy { $0.r == $0.g && $0.g == $0.b })
        // The lighter the cover, the lighter the grey blobs.
        let bright = ArtTheme(from: [BlobColor(r: 230, g: 230, b: 230, hue: 0)])
        #expect(bright.blobs[0].r > art.blobs[0].r)
        // No colours at all: a fixed grey.
        let none = ArtTheme(from: [])
        #expect(none.blobs.count == 2 && none.start == "#505050")
    }
}
