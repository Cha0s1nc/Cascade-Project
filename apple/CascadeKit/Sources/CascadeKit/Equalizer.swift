import Foundation

/// The 5-band equalizer's data and maths, the desktop's
/// src/core/eq-profile.ts: the same bands, limits, presets and auto preamp,
/// so a curve means the same on both. AudioTap applies it.
public struct EQProfile: Codable, Sendable, Equatable {
    public static let bands: [Double] = [60, 250, 1000, 4000, 12000]
    public static let gainLimit = 12.0
    /// ~1.4 octaves wide, the desktop's EQ_FILTER_Q: narrow enough that five
    /// bands spanning the range stay distinct, wide enough to sound smooth.
    public static let q = 1.0

    public static let presets: [(name: String, bands: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0]),
        ("Bass Boost", [7, 4, 0, -1, -1]),
        ("Vocal", [-3, -1, 4, 3, -1]),
        ("Treble", [-2, -1, 0, 4, 6]),
        ("Loudness", [6, 2, -2, 2, 6]),
    ]

    public var enabled = false
    /// nil is "auto": autoPreamp of the curve.
    public var preamp: Double?
    public var gains: [Double] = [0, 0, 0, 0, 0]

    public init(enabled: Bool = false, preamp: Double? = nil, gains: [Double] = [0, 0, 0, 0, 0]) {
        self.enabled = enabled
        self.preamp = preamp
        self.gains = gains
    }

    public static func clamp(_ db: Double) -> Double { max(-gainLimit, min(gainLimit, db)) }

    public static func linear(_ db: Double) -> Double { pow(10, db / 20) }

    /// Cut the preamp by the biggest boost, so a boosted band cannot push
    /// the signal past where it would have been flat. Never positive.
    public static func autoPreamp(_ gains: [Double]) -> Double {
        -gains.reduce(0) { max($0, $1.isFinite ? $1 : 0) }
    }

    public var effectivePreamp: Double { preamp ?? Self.autoPreamp(gains) }

    /// Whether it changes anything at all.
    public var isFlat: Bool { !enabled || (gains.allSatisfy { $0 == 0 } && effectivePreamp == 0) }

    /// The name of the preset this curve is, if any.
    public var presetName: String? { Self.presets.first { $0.bands == gains }?.name }

    /// A stored profile, which can be anything: every gain clamped, missing
    /// bands flat, garbage an off, flat profile.
    public static func decode(_ data: Data?) -> EQProfile {
        guard let data, let raw = try? JSONDecoder().decode(EQProfile.self, from: data) else { return EQProfile() }
        var gains = bands.indices.map { i in i < raw.gains.count && raw.gains[i].isFinite ? clamp(raw.gains[i]) : 0 }
        if gains.count != bands.count { gains = [0, 0, 0, 0, 0] }
        return EQProfile(enabled: raw.enabled, preamp: raw.preamp.flatMap { $0.isFinite ? clamp($0) : nil }, gains: gains)
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// One second-order filter's coefficients, normalized so a0 is 1: the RBJ
/// Audio EQ Cookbook peaking filter, which is what Web Audio's 'peaking'
/// BiquadFilterNode is, so the desktop and this sound alike.
public struct Biquad: Sendable, Equatable {
    public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    public static let identity = Biquad()

    public static func peaking(frequency: Double, gainDb: Double, q: Double, sampleRate: Double) -> Biquad {
        guard gainDb != 0, sampleRate > 0, frequency < sampleRate / 2 else { return .identity }
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    /// Gain in dB at a frequency: for tests, and a sanity check on the maths.
    public func responseDb(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func mag(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(mag(b0, b1, b2) / mag(1, a1, a2))
    }
}
