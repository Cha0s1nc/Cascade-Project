import Foundation
import AVFoundation
import MediaToolbox
import os

/// The EQ and the normalization gain, applied inside AVFoundation's pipeline
/// through an MTAudioProcessingTap on each player item: the counterpart of
/// the desktop's Web Audio graph (preamp and normalization gain into five
/// peaking filters).
///
/// Per item rather than per player, so the gain of the track after a gapless
/// handover changes at the exact sample it starts, and so a boost is
/// possible at all (AVPlayer's volume stops at 1).
///
/// ponytail: no tap on an HLS transcode, which AVFoundation does not let one
/// see, so a capped streaming quality plays without EQ and with
/// attenuation-only normalization, as before. Progressive transcodes would
/// fix it if that combination turns out to matter.
public final class TapContext: @unchecked Sendable {
    private static let bandCount = EQProfile.bands.count
    private static let maxChannels = 8

    /// What the main actor asks for, read by the audio thread when it can
    /// take the lock without waiting.
    private struct Settings {
        var profile = EQProfile()
        var normalization: Float = 1
        var sampleRate: Double = 0
        var dirty = true
    }
    private let settings = OSAllocatedUnfairLock(initialState: Settings())

    // Audio-thread state. Only touched from prepare and process, which
    // AVFoundation never runs at the same time.
    private let coefficients = UnsafeMutablePointer<Double>.allocate(capacity: bandCount * 5)
    private let history = UnsafeMutablePointer<Double>.allocate(capacity: maxChannels * bandCount * 2)
    private var gain: Float = 1
    private var filtering = false
    private var usable = false

    public init() {
        coefficients.initialize(repeating: 0, count: Self.bandCount * 5)
        history.initialize(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
    }

    deinit {
        coefficients.deallocate()
        history.deallocate()
    }

    /// How loud the last buffer was, 0 to 1, falling away between buffers: the Mac's playing-row
    /// bars follow it when a tap happens to be attached (the EQ is on). The audio thread only
    /// try-takes the lock, so a read from the main actor can never make it wait.
    private let levelStore = OSAllocatedUnfairLock(initialState: Float(0))
    public var level: Float { levelStore.withLock { $0 } }

    public func update(profile: EQProfile? = nil, normalization: Float? = nil) {
        settings.withLock {
            if let profile { $0.profile = profile }
            if let normalization { $0.normalization = normalization }
            $0.dirty = true
        }
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        // Float, non-interleaved is what the tap hands over in practice;
        // anything else passes through untouched rather than as noise.
        usable = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
            && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            && Int(format.mChannelsPerFrame) <= Self.maxChannels
        history.update(repeating: 0, count: Self.maxChannels * Self.bandCount * 2)
        debugLog("audio tap: \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(usable ? "processing" : "passing through")")
        settings.withLock {
            $0.sampleRate = format.mSampleRate
            $0.dirty = true
        }
    }

    /// Picks up new settings when the lock is free, else keeps the last ones
    /// for this buffer: the audio thread never waits on the main one.
    private func refresh() {
        guard let next = settings.withLockIfAvailable({ s -> Settings? in
            guard s.dirty else { return nil }
            s.dirty = false
            return s
        }), let next else { return }
        let profile = next.profile
        filtering = profile.enabled && !profile.gains.allSatisfy { $0 == 0 }
        for i in 0..<Self.bandCount {
            let db = profile.enabled && i < profile.gains.count ? profile.gains[i] : 0
            let c = Biquad.peaking(frequency: EQProfile.bands[i], gainDb: db, q: EQProfile.q, sampleRate: next.sampleRate)
            let base = coefficients + i * 5
            base[0] = c.b0; base[1] = c.b1; base[2] = c.b2; base[3] = c.a1; base[4] = c.a2
        }
        let preamp = profile.enabled ? Float(EQProfile.linear(profile.effectivePreamp)) : 1
        gain = preamp * next.normalization
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard usable else { return }
        refresh()
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        // Peak of the first channel, before the early return: a flat tap still has a level.
        if let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) {
            var peak: Float = 0
            for n in 0..<min(frames, Int(first.mDataByteSize) / MemoryLayout<Float>.size) { peak = max(peak, abs(data[n])) }
            let heard = min(1, peak)
            _ = levelStore.withLockIfAvailable { $0 = max(heard, $0 * 0.85) }
        }
        if !filtering && gain == 1 { return }
        for (channel, buffer) in buffers.enumerated() where channel < Self.maxChannels {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            let state = history + channel * Self.bandCount * 2
            for n in 0..<count {
                var x = Double(data[n] * gain)
                if filtering {
                    // Transposed direct form II, one biquad per band.
                    for b in 0..<Self.bandCount {
                        let c = coefficients + b * 5
                        let z = state + b * 2
                        let y = c[0] * x + z[0]
                        z[0] = c[1] * x - c[3] * y + z[1]
                        z[1] = c[2] * x - c[4] * y
                        x = y
                    }
                }
                data[n] = Float(x)
            }
        }
    }
}

public enum AudioTap {
    /// Puts a tap running `context` on the item's audio. False when there is
    /// no audio track to put one on (an HLS transcode), which plays as is.
    @MainActor
    public static func attach(_ context: TapContext, to item: AVPlayerItem) async -> Bool {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return false }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, list, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(list, frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(context).release()   // the retain handed to clientInfo
            return false
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
        return true
    }
}
