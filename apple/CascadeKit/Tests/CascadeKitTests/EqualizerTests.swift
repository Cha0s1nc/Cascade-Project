import Foundation
import Testing
import AVFoundation
@testable import CascadeKit

// The profile cases are ported from the desktop's test/eq-profile.test.ts.
struct EqualizerTests {
    @Test func garbageDecodesToAnOffFlatProfile() {
        #expect(EQProfile.decode(nil) == EQProfile())
        #expect(EQProfile.decode(Data("{".utf8)) == EQProfile())
        let wild = EQProfile.decode(Data(#"{"enabled":true,"preamp":99,"gains":[40,-40,3]}"#.utf8))
        #expect(wild.gains == [12, -12, 3, 0, 0])
        #expect(wild.preamp == 12)
        #expect(wild.enabled)
    }

    @Test func aMissingPreampIsAuto() {
        let p = EQProfile.decode(Data(#"{"enabled":true,"gains":[6,0,0,0,0]}"#.utf8))
        #expect(p.preamp == nil)
        #expect(p.effectivePreamp == -6)
    }

    @Test func autoPreampCutsByTheBiggestBoostAndNeverBoosts() {
        #expect(EQProfile.autoPreamp([0, 0, 0, 0, 0]) == 0)
        #expect(EQProfile.autoPreamp([-6, -3, 0, -1, -2]) == 0)
        #expect(EQProfile.autoPreamp([7, 4, 0, -1, -1]) == -7)
        #expect(EQProfile.autoPreamp([2, 9, 0, 0, 0]) < EQProfile.autoPreamp([2, 3, 0, 0, 0]))
    }

    @Test func everyPresetFitsTheBands() {
        for preset in EQProfile.presets {
            #expect(preset.bands.count == EQProfile.bands.count, "\(preset.name)")
            #expect(preset.bands.allSatisfy { abs($0) <= EQProfile.gainLimit }, "\(preset.name)")
        }
        #expect(EQProfile(gains: [7, 4, 0, -1, -1]).presetName == "Bass Boost")
    }

    @Test func aPeakingFilterBoostsItsBandAndLeavesTheRestAlone() {
        let rate = 44100.0
        let f = Biquad.peaking(frequency: 1000, gainDb: 6, q: EQProfile.q, sampleRate: rate)
        #expect(abs(f.responseDb(at: 1000, sampleRate: rate) - 6) < 0.01)
        #expect(abs(f.responseDb(at: 60, sampleRate: rate)) < 0.3)
        #expect(abs(f.responseDb(at: 15000, sampleRate: rate)) < 0.3)
        #expect(Biquad.peaking(frequency: 1000, gainDb: 0, q: 1, sampleRate: rate) == .identity)
        // A band above Nyquist (12 kHz at a low rate) is left out, not unstable.
        #expect(Biquad.peaking(frequency: 12000, gainDb: 6, q: 1, sampleRate: 22050) == .identity)
    }

    @Test func aFlatOrDisabledProfileIsFlat() {
        #expect(EQProfile().isFlat)
        #expect(EQProfile(enabled: false, gains: [6, 0, 0, 0, 0]).isFlat)
        #expect(!EQProfile(enabled: true, gains: [6, 0, 0, 0, 0]).isFlat)
        #expect(!EQProfile(enabled: true, preamp: -3).isFlat)
    }
}

/// The tap's own processing, fed sine waves: what reaches the speaker.
struct TapProcessingTests {
    private let rate = 44100.0

    /// RMS of a sine at `hz` after the tap, over the last half second (the
    /// filters settle first).
    private func rms(_ context: TapContext, hz: Double) -> Double {
        let format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        context.prepare(format)
        let frames = 512
        var total = 0.0, count = 0, n = 0
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { samples.deallocate() }
        for block in 0..<Int(rate / Double(frames)) {
            for i in 0..<frames { samples[i] = Float(0.25 * sin(2 * .pi * hz * Double(n + i) / rate)) }
            n += frames
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(samples)))
            context.process(&list, frames: frames)
            if block >= Int(rate / Double(frames)) / 2 {
                for i in 0..<frames { total += Double(samples[i] * samples[i]); count += 1 }
            }
        }
        return (total / Double(count)).squareRoot()
    }

    private func db(_ ratio: Double) -> Double { 20 * log10(ratio) }
    private let flat = 0.25 / 2.0.squareRoot()

    @Test func offLeavesTheSignalAlone() {
        let context = TapContext()
        #expect(abs(db(rms(context, hz: 1000) / flat)) < 0.05)
    }

    @Test func aBandBoostLandsOnItsBandOnly() {
        let context = TapContext()
        context.update(profile: EQProfile(enabled: true, preamp: 0, gains: [0, 0, 6, 0, 0]))
        #expect(abs(db(rms(context, hz: 1000) / flat) - 6) < 0.2)
        let other = TapContext()
        other.update(profile: EQProfile(enabled: true, preamp: 0, gains: [0, 0, 6, 0, 0]))
        #expect(abs(db(rms(other, hz: 60) / flat)) < 0.5)
    }

    @Test func autoPreampAndNormalizationMultiply() {
        let context = TapContext()
        // Auto preamp -6 for the +6 band, measured away from the band, plus a
        // +4 dB normalization boost: -2 dB overall.
        context.update(profile: EQProfile(enabled: true, gains: [0, 0, 0, 0, 6]), normalization: Float(EQProfile.linear(4)))
        #expect(abs(db(rms(context, hz: 250) / flat) - (-2)) < 0.3)
    }
}
