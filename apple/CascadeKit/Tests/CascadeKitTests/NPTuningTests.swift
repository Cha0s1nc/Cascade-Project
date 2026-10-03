import Foundation
import Testing
@testable import CascadeKit

// Ported from test/np-tuning.test.ts and test/font.test.ts.
@Suite struct NPTuningTests {
    @Test func lyricScaleKeepsAnInRangeValueAndClampsTheRest() {
        #expect(NPTuning.clampLyricScale(1) == 1)
        #expect(NPTuning.clampLyricScale(0.9) == 0.9)
        #expect(NPTuning.clampLyricScale(1.25) == 1.25)
        #expect(NPTuning.clampLyricScale(0.1) == NPTuning.lyricScaleRange.lowerBound)
        #expect(NPTuning.clampLyricScale(5) == NPTuning.lyricScaleRange.upperBound)
        #expect(NPTuning.clampLyricScale(-1) == NPTuning.lyricScaleRange.lowerBound)
    }

    @Test func garbageAlwaysYieldsAFiniteDefault() {
        for garbage in [Double.nan, .infinity, -.infinity] {
            #expect(NPTuning.clampLyricScale(garbage) == NPTuning.lyricScaleDefault)
            #expect(NPTuning.clampBgDim(garbage) == NPTuning.bgDimDefault)
        }
        #expect(NPTuning.clampLyricScale(nil) == NPTuning.lyricScaleDefault)
        #expect(NPTuning.clampBgDim(nil) == NPTuning.bgDimDefault)
    }

    @Test func bgDimKeepsAnInRangeValueAndClamps() {
        #expect(NPTuning.clampBgDim(0.35) == 0.35)
        #expect(NPTuning.clampBgDim(-2) == NPTuning.bgDimRange.lowerBound)
        #expect(NPTuning.clampBgDim(9) == NPTuning.bgDimRange.upperBound)
    }

    @Test func onlyAnExplicitFalseTurnsMultiplyOff() {
        #expect(NPTuning.clampBgBlend(false) == false)
        #expect(NPTuning.clampBgBlend(true) == true)
        #expect(NPTuning.clampBgBlend(nil) == true)
        #expect(NPTuning.clampBgBlend("normal") == true)
    }

    @Test func storedValuesRoundTripAndGarbageGivesDefaults() {
        var v = NPTuning.Values()
        v.bgDim = 0.4
        v.bgBlend = false
        #expect(NPTuning.Values(stored: v.encoded()) == v)
        #expect(NPTuning.Values(stored: "not json") == NPTuning.Values())
        #expect(NPTuning.Values(stored: nil) == NPTuning.Values())
        #expect(NPTuning.Values(stored: #"{"lyricScale":"big","bgDim":99,"bgBlend":"no"}"#).bgDim == 1)
        #expect(NPTuning.Values(stored: #"{"lyricScale":"big"}"#).lyricScale == NPTuning.lyricScaleDefault)
    }
}

@Suite struct AppFontTests {
    @Test func sanitizeStripsAnythingOutsideLettersDigitsSpacesHyphens() {
        #expect(AppFont.sanitize("Comic Sans MS") == "Comic Sans MS")
        #expect(AppFont.sanitize("Fira Code") == "Fira Code")
        #expect(AppFont.sanitize("\"; } body { display:none") == "  body  displaynone")
        #expect(AppFont.sanitize("Evil'); DROP TABLE fonts;--") == "Evil DROP TABLE fonts--")
    }

    @Test func sanitizeCapsLengthAndRejectsNonStrings() {
        #expect(AppFont.sanitize(String(repeating: "a", count: 200)).count == 60)
        #expect(AppFont.sanitize(nil) == "")
        #expect(AppFont.sanitize("   ") == "")
    }

    @Test func knownPresetsResolve() {
        #expect(AppFont.resolve(preset: "sans") == .family("Helvetica"))
        #expect(AppFont.resolve(preset: "serif") == .family("Georgia"))
        #expect(AppFont.resolve(preset: "mono") == .monospaced)
        #expect(AppFont.resolve(preset: "system") == .system)
    }

    @Test func anUnknownOrMissingPresetFallsBackToSystem() {
        #expect(AppFont.resolve(preset: nil) == .system)
        #expect(AppFont.resolve(preset: "a-stale-preset-id-from-an-old-build") == .system)
        #expect(AppFont.validPreset("a-stale-preset-id-from-an-old-build") == "system")
        #expect(AppFont.validPreset("custom") == "custom")
    }

    @Test func aCustomNameResolvesAndNeverCarriesStrippedPunctuation() {
        #expect(AppFont.resolve(preset: "custom", custom: "Fira Code") == .family("Fira Code"))
        #expect(AppFont.resolve(preset: "custom", custom: "Evil\"); } * { color: red") == .family("Evil    color red"))
    }

    @Test func aCustomChoiceWithNoUsableNameFallsBackToSystem() {
        #expect(AppFont.resolve(preset: "custom", custom: "") == .system)
        #expect(AppFont.resolve(preset: "custom", custom: nil) == .system)
        #expect(AppFont.resolve(preset: "custom", custom: ";{}/*\"") == .system)
    }
}
