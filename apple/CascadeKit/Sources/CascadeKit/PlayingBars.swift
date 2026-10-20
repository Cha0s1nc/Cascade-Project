import Foundation

/// The playing-row bars, from real audio: the desktop's eqLevels (src/core/eq.ts) and the
/// Web Audio analyser it reads (fftSize 64, Blackman window, 0.75 smoothing, -100 to -30 dB
/// as 0 to 255), so both apps' bars move the same way. TapContext runs the spectrum on the
/// audio thread, so nothing here allocates.
public enum PlayingBars {
    public static let count = 7
    /// A dead-flat bar reads as broken, not quiet.
    public static let minHeight: Float = 0.12
    static let lowGain: Float = 1.0
    static let highGain: Float = 2.8

    /// Bar heights, lowest frequency first, from analyser-style byte levels (0 to 255) per
    /// bin. Bands are spaced logarithmically and each gets at least one bin. Bin 0 is DC.
    public static func levels(_ bins: UnsafeBufferPointer<Float>) -> SIMD8<Float> {
        var out = SIMD8<Float>(repeating: minHeight)
        let n = bins.count
        guard n >= 2 else { return out }
        var start = 1
        for k in 0..<count {
            let edge = Int(pow(Double(n), Double(k + 1) / Double(count)))
            let end = min(n, max(start + 1, edge))
            var sum: Float = 0
            for i in start..<max(start, end) { sum += bins[i] }
            let avg = end > start ? sum / Float(end - start) : 0
            let gain = lowGain + (highGain - lowGain) * Float(k) / Float(count - 1)
            out[k] = min(1, max(minHeight, avg / 255 * gain))
            start = end
        }
        return out
    }
}

/// The analyser half: a 64-point spectrum of the newest samples, smoothed between buffers.
/// Built once per tap; `measure` is called from the audio thread.
final class BarSpectrum {
    static let size = 64
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
    private let cosines = UnsafeMutablePointer<Float>.allocate(capacity: size * size / 2)
    private let sines = UnsafeMutablePointer<Float>.allocate(capacity: size * size / 2)
    private let smoothed = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
    private let bytes = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)

    init() {
        let n = Self.size
        for i in 0..<n {
            let x = 2 * Double.pi * Double(i) / Double(n)
            window[i] = Float(0.42 - 0.5 * cos(x) + 0.08 * cos(2 * x))
        }
        for k in 0..<n / 2 {
            for i in 0..<n {
                let a = 2 * Double.pi * Double(k * i) / Double(n)
                cosines[k * n + i] = Float(cos(a))
                sines[k * n + i] = Float(sin(a))
            }
        }
        smoothed.initialize(repeating: 0, count: n / 2)
        bytes.initialize(repeating: 0, count: n / 2)
    }

    deinit {
        window.deallocate(); cosines.deallocate(); sines.deallocate(); smoothed.deallocate(); bytes.deallocate()
    }

    /// Bar heights from the last `size` of `count` samples. A plain DFT: 32 bins of 64 is
    /// about two thousand multiplies a buffer, not worth an FFT setup.
    func measure(_ samples: UnsafePointer<Float>, count: Int) -> SIMD8<Float> {
        let n = Self.size
        let from = samples + max(0, count - n)
        let have = min(count, n)
        for k in 0..<n / 2 {
            var re: Float = 0, im: Float = 0
            for i in 0..<have {
                let x = from[i] * window[i]
                re += x * cosines[k * n + i]
                im -= x * sines[k * n + i]
            }
            let magnitude = (re * re + im * im).squareRoot() / Float(n)
            smoothed[k] = 0.75 * smoothed[k] + 0.25 * magnitude
            let db = 20 * log10(max(smoothed[k], 1e-10))
            bytes[k] = min(255, max(0, (db + 100) / 70 * 255))
        }
        return PlayingBars.levels(UnsafeBufferPointer(start: bytes, count: n / 2))
    }
}
