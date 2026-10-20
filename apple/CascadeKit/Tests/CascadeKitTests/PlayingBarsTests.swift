import Testing
import Foundation
@testable import CascadeKit

// The desktop's test/eq.test.ts cases, against the Swift port.
@Suite struct PlayingBarsTests {
    private func levels(_ bins: [Float]) -> SIMD8<Float> { bins.withUnsafeBufferPointer { PlayingBars.levels($0) } }

    @Test func drawsAtLeastSixBars() { #expect(PlayingBars.count >= 6 && PlayingBars.count <= 8) }

    @Test func silenceIsFlat() {
        let out = levels(Array(repeating: 0, count: 32))
        for i in 0..<PlayingBars.count { #expect(out[i] == PlayingBars.minHeight) }
    }

    @Test func aLoudLowBandRaisesOnlyTheLowBars() {
        var bins = [Float](repeating: 0, count: 32)
        for i in 1..<4 { bins[i] = 255 }
        let out = levels(bins)
        #expect(out[0] > PlayingBars.minHeight)
        #expect(out[PlayingBars.count - 1] == PlayingBars.minHeight)
    }

    @Test func everyBarGetsItsOwnBins() {
        var bins = [Float](repeating: 0, count: 32)
        bins[31] = 255
        let out = levels(bins)
        #expect(out[PlayingBars.count - 1] > PlayingBars.minHeight)
        for i in 0..<PlayingBars.count - 1 { #expect(out[i] == PlayingBars.minHeight) }
    }

    @Test func aBassToneRaisesTheFirstBarAndNotTheLast() {
        // 200 Hz at 44.1 kHz, buffer after buffer so the smoothing settles.
        let spectrum = BarSpectrum()
        let tone = (0..<4096).map { Float(sin(2 * Double.pi * 200 * Double($0) / 44_100)) * 0.5 }
        var out = SIMD8<Float>()
        for _ in 0..<20 { out = tone.withUnsafeBufferPointer { spectrum.measure($0.baseAddress!, count: $0.count) } }
        #expect(out[0] > 0.5)
        #expect(out[PlayingBars.count - 1] < out[0])
    }
}
