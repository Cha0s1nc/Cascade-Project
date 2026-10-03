import Foundation
import Testing
@testable import CascadeKit

// Ported from the desktop's test/album-colors.test.ts: the properties the old
// extraction got wrong in ways only visible on screen.
@Suite struct AlbumColorsTests {
    /// Packed RGBA from (count, r, g, b) runs.
    private func cover(_ runs: (Int, UInt8, UInt8, UInt8)...) -> [UInt8] {
        runs.flatMap { run in (0..<run.0).flatMap { _ in [run.1, run.2, run.3, 255] } }
    }

    private func dist(_ a: BlobColor, _ r: Double, _ g: Double, _ b: Double) -> Double {
        ((a.r - r) * (a.r - r) + (a.g - g) * (a.g - g) + (a.b - b) * (a.b - b)).squareRoot()
    }

    @Test func rejectsABufferThatIsNotPackedRGBA() {
        #expect(throws: AlbumColors.NotPackedRGBA.self) { try AlbumColors.extractTopColors([UInt8](repeating: 0, count: 7)) }
    }

    @Test func anEmptyOrTransparentCoverGivesNoColors() throws {
        #expect(try AlbumColors.extractTopColors([]).isEmpty)
        #expect(try AlbumColors.extractTopColors([UInt8](repeating: 0, count: 40)).isEmpty)
    }

    @Test func findsTheColorsThatArePresent() throws {
        let got = try AlbumColors.extractTopColors(cover((200, 200, 30, 60), (200, 40, 70, 200)), count: 2)
        #expect(got.count == 2)
        let nearCrimson = got.filter { dist($0, 200, 30, 60) < dist($0, 40, 70, 200) }
        #expect(nearCrimson.count == 1)
    }

    @Test func aSmallVividAccentBeatsALargeDullField() throws {
        let top = try #require(try AlbumColors.extractTopColors(cover((900, 190, 180, 165), (100, 230, 20, 180)), count: 1).first)
        #expect(dist(top, 230, 20, 180) < dist(top, 190, 180, 165))
    }

    @Test func keepsHowLightOrDarkAColorIs() throws {
        let pastel = try #require(try AlbumColors.extractTopColors(cover((400, 240, 200, 215)), count: 1).first)
        let deep = try #require(try AlbumColors.extractTopColors(cover((400, 120, 20, 55)), count: 1).first)
        let lum = { (c: BlobColor) in AlbumColors.oklab(r: c.r, g: c.g, b: c.b).L }
        #expect(lum(pastel) > lum(deep) + 0.1)
    }

    @Test func theSameCoverAlwaysGivesTheSameColors() throws {
        let px = cover((300, 30, 140, 90), (300, 210, 60, 30), (200, 60, 60, 190))
        #expect(try AlbumColors.extractTopColors(px) == AlbumColors.extractTopColors(px))
    }

    @Test func doesNotReturnThreeIdenticalShades() throws {
        let got = try AlbumColors.extractTopColors(cover((300, 200, 40, 40), (300, 170, 34, 34), (300, 220, 55, 55)))
        for i in got.indices { for j in got.indices where j > i { #expect(dist(got[i], got[j].r, got[j].g, got[j].b) > 1) } }
    }

    @Test func oklabSurvivesARoundTrip() {
        for (r, g, b) in [(0.0, 0.0, 0.0), (255, 255, 255), (200, 30, 60), (40, 70, 200), (128, 128, 128)] {
            let back = AlbumColors.srgb(AlbumColors.oklab(r: r, g: g, b: b))
            #expect(abs(back.r - r) <= 1 && abs(back.g - g) <= 1 && abs(back.b - b) <= 1)
        }
    }

    @Test func blobsStayInTheDarkThemeLightnessWindow() throws {
        // A near-black-but-kept and a near-white-but-kept cover both land inside.
        for px in [cover((400, 40, 10, 20)), cover((400, 240, 235, 250))] {
            let c = try #require(try AlbumColors.extractTopColors(px, count: 1).first)
            let L = AlbumColors.oklab(r: c.r, g: c.g, b: c.b).L
            #expect(L >= AlbumColors.minL - 0.02 && L <= AlbumColors.maxL + 0.02)
        }
    }

    @Test func driftMovesTheBlobsButKeepsThemOnScreen() throws {
        let colors = try AlbumColors.extractTopColors(cover((300, 200, 30, 60), (300, 40, 70, 200)))
        let drift = AlbumColors.randomizeDrift(count: 3) { 0.5 }
        #expect(AlbumColors.driftedBlobs(colors, drift: drift, at: 0).map(\.x)
                != AlbumColors.driftedBlobs(colors, drift: drift, at: 9).map(\.x))
        for t in [0.0, 3, 7, 21, 60] {
            for b in AlbumColors.driftedBlobs(colors, drift: drift, at: t) {
                #expect(b.x > -20 && b.x < 120 && b.y > -20 && b.y < 120)
            }
        }
    }

    @Test func brightCoversReadBrighterThanDarkOnes() {
        let salmon = BlobColor(r: 225, g: 110, b: 85, hue: 0)
        let navy = BlobColor(r: 40, g: 50, b: 110, hue: 0)
        let bright = AlbumColors.brightness([salmon, salmon, salmon])
        let dark = AlbumColors.brightness([navy, navy, navy])
        #expect(bright > 0.6 && bright < 0.75)
        #expect(dark < 0.4)
        #expect(AlbumColors.brightness([]) == 0)
        // The big blobs count for more than the small one.
        #expect(AlbumColors.brightness([salmon, salmon, navy]) > AlbumColors.brightness([navy, navy, salmon]))
    }

    // The light theme, from test/album-colors.test.ts.

    @Test func eachThemeClampsBlobLightnessIntoItsOwnWindow() throws {
        // Asserted against the configured window, not literals: these numbers are a tuning
        // knob that moved three times on the desktop. The slack is the sRGB round trip, which
        // clips a deep saturated colour at a low L back into gamut and reads a little lighter.
        let deepRed = cover((400, 140, 20, 30))
        for light in [false, true] {
            let blob = try #require(try AlbumColors.extractTopColors(deepRed, count: 1, light: light).first)
            let window = light ? AlbumColors.lightnessRange.light : AlbumColors.lightnessRange.dark
            let L = AlbumColors.oklab(r: blob.r, g: blob.g, b: blob.b).L
            #expect(L >= window.min - 0.06 && L <= window.max + 0.06, "light=\(light) L=\(L)")
        }
    }

    @Test func theTwoThemesClampIntoGenuinelyDifferentWindows() {
        // Light is not "dark, but paler": multiply blending makes a light-theme blob ink on paper.
        let d = AlbumColors.lightnessRange.dark, l = AlbumColors.lightnessRange.light
        #expect(d.min < d.max && l.min < l.max)
        #expect(d.min != l.min || d.max != l.max)
        #expect(l.max < d.min)
    }

    @Test func lightModeKeepsBlobLayoutIdenticalToDark() throws {
        let colors = try AlbumColors.extractTopColors(cover((300, 200, 30, 60), (300, 40, 70, 200)), count: 2)
        let drift = AlbumColors.randomizeDrift(count: 2) { 0.5 }
        let dark = AlbumColors.driftedBlobs(colors, drift: drift, at: 5)
        let light = AlbumColors.driftedBlobs(colors, drift: drift, at: 5, light: true)
        for (d, l) in zip(dark, light) {
            // Position and size are the invariant; alpha is a tuning knob.
            #expect(d.x == l.x && d.y == l.y && d.w == l.w && d.h == l.h)
        }
    }

    @Test func theLightBaseMatchesTheLightAppBackground() {
        #expect(Int((AlbumColors.baseLight.r * 255).rounded()) == 0xf2)
        #expect(Int((AlbumColors.baseLight.b * 255).rounded()) == 0xf7)
    }
}
