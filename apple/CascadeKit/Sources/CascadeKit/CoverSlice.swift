import Foundation

/// The crossfade cover slice: the desktop's startArtSlice (renderer.js), from
/// docs/demos/album-art-slice-transition.html. When a crossfade starts, the
/// outgoing cover is cut from the bottom-right corner to the diagonal, holds
/// half and half for the rest of the fade, then the cut slides off through the
/// top-left corner once the old song is gone. A fade cut short (pause, skip,
/// seek) slides it out from wherever it is.
///
/// The cut is the line x + y = s across the unit square: 2 is the bottom-right
/// corner (nothing cut), 1 the diagonal (half and half), 0 the top-left corner.
public enum CoverSlice {
    public static let sliceInDefault = 0.8
    public static let slideOutDefault = 1.2
    public static let sliceInRange = 0.2...2.0
    public static let slideOutRange = 0.3...3.0

    /// Where the cut is `t` seconds after the fade started, or nil once it has
    /// slid off. `cutAt` is when the fade ended early, if it did.
    public static func cut(at t: Double, fade: Double, cutAt: Double? = nil,
                           sliceIn: Double = sliceInDefault, slideOut: Double = slideOutDefault) -> Double? {
        let slideFrom = min(cutAt ?? fade, fade)
        if t < slideFrom { return held(at: t, fade: fade, sliceIn: sliceIn) }
        let s0 = held(at: slideFrom, fade: fade, sliceIn: sliceIn)
        // A cut still near the corner has less far to go, so it goes quicker.
        let length = slideOut * min(1, s0)
        guard length > 0 else { return nil }
        let u = (t - slideFrom) / length
        return u >= 1 ? nil : s0 * (1 - easeInOutCubic(u))
    }

    /// The seam's brightness, 0 to 1: bright while it moves in, settled while
    /// it holds, flaring then gone as it leaves.
    public static func seam(at t: Double, fade: Double, cutAt: Double? = nil,
                            sliceIn: Double = sliceInDefault, slideOut: Double = slideOutDefault) -> Double {
        let slideFrom = min(cutAt ?? fade, fade)
        let into = min(sliceIn, fade)
        if t < slideFrom { return t < into ? 1 - 0.45 * max(0, t) / into : 0.55 }
        let s0 = held(at: slideFrom, fade: fade, sliceIn: sliceIn)
        let u = (t - slideFrom) / max(0.001, slideOut * min(1, s0))
        return u < 0.3 ? 0.55 + 0.45 * u / 0.3 : max(0, 1 - (u - 0.3) / 0.7)
    }

    static func held(at t: Double, fade: Double, sliceIn: Double) -> Double {
        let into = min(sliceIn, fade)
        guard into > 0, t < into else { return 1 }
        return 2 - easeOutCubic(max(0, t) / into)
    }

    static func easeOutCubic(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
    static func easeInOutCubic(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
}

/// A crossfade that is changing the cover, as PlaybackService reports it.
public struct CrossfadeArt: Equatable, Sendable {
    /// The art ids (album, else item) going out and coming in.
    public let outgoing: String
    public let incoming: String
    public let started: Date
    /// The fade's real length, which can be shorter than the setting near a song's end.
    public let duration: Double
    /// When the fade ended early (pause, skip, seek), if it did.
    public var cutAt: Date?

    public init(outgoing: String, incoming: String, started: Date, duration: Double, cutAt: Date? = nil) {
        (self.outgoing, self.incoming, self.started, self.duration, self.cutAt) = (outgoing, incoming, started, duration, cutAt)
    }
}
