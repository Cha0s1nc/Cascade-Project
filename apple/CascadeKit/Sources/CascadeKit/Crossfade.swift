import Foundation

/// The desktop's src/core/crossfade.ts: the equal-power envelope and how
/// long a fade may actually run.
public enum Crossfade {
    /// Settings range, the desktop's slider: 1 to 15 s, 6 by default.
    public static let range = 1...15
    public static let defaultSeconds = 6

    /// Below this a "fade" is a hard cut with a smear on it, landing
    /// mid-phrase because the outgoing track is ended early to make room.
    public static let minUsefulSeconds = 1.0

    /// Gains for the outgoing and incoming track at `progress` (0 to 1).
    /// cos/sin rather than straight lines: loudness follows power, and two
    /// linear ramps sum to half the power halfway through, an audible dip.
    public static func gains(at progress: Double) -> (out: Float, in: Float) {
        let angle = min(1, max(0, progress)) * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// How long to fade, given the setting and what is really left of the
    /// outgoing track; nil when too little is left to be worth fading.
    public static func duration(configured: Double, remaining: Double) -> Double? {
        guard remaining.isFinite else { return configured > 0 ? configured : nil }
        guard remaining >= minUsefulSeconds else { return nil }
        let seconds = min(configured, remaining)
        return seconds >= minUsefulSeconds ? seconds : nil
    }
}
