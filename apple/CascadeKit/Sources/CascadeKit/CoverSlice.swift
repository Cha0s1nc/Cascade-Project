import Foundation

/// The crossfade cover slice: the desktop's startArtSlice (renderer.js), from
/// docs/demos/album-art-slice-transition.html. When a crossfade starts, the
/// outgoing cover is cut from the bottom-right corner to the diagonal, holds
/// half and half for the rest of the fade, then the cut slides off through the
/// top-left corner once the old song is gone. A fade cut short (pause, skip,
/// seek) slides it out from wherever it is. That is the default: the style,
/// direction, hold and easing are settings, under the desktop's names and values.
///
/// Every style runs on one number, s: 2 is all old cover, 1 half and half, 0
/// all new. For the default slice it is the cut x + y = s across the unit square.
public enum CoverSlice {
    public static let sliceInDefault = 0.8
    public static let slideOutDefault = 1.2
    public static let sliceInRange = 0.2...2.0
    public static let slideOutRange = 0.3...3.0
    /// The seam's glow and the edge shadow, times their default strength.
    public static let strengthRange = 0.0...2.0

    /// Slice cuts the old cover away, Fade dissolves it, Push slides the new one in.
    public enum Style: String, CaseIterable, Sendable { case slice, fade, push }

    /// The way the cut, or the old cover, moves.
    public enum Direction: String, CaseIterable, Sendable {
        case upLeft = "up-left", up, upRight = "up-right", right, downRight = "down-right", down, downLeft = "down-left", left
        /// As screen axes, y down: each part -1, 0 or 1.
        public var move: (x: Double, y: Double) {
            switch self {
            case .upLeft: (-1, -1)
            case .up: (0, -1)
            case .upRight: (1, -1)
            case .right: (1, 0)
            case .downRight: (1, 1)
            case .down: (0, 1)
            case .downLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }
        public var isDiagonal: Bool { move.x != 0 && move.y != 0 }
    }

    /// Where the cut waits while both songs play; a sweep never waits.
    public enum Hold: String, CaseIterable, Sendable {
        case half, old, new, sweep
        public var s: Double {
            switch self {
            case .half: 1
            case .old: 1.4
            case .new: 0.6
            case .sweep: 0
            }
        }
    }

    /// Cut in eases out and slide out eases in and out, in cubic (the demo's), quint, or not at all.
    public enum Easing: String, CaseIterable, Sendable {
        case smooth, snappy, linear
        func into(_ u: Double) -> Double {
            switch self {
            case .smooth: 1 - pow(1 - u, 3)
            case .snappy: 1 - pow(1 - u, 5)
            case .linear: u
            }
        }
        func out(_ u: Double) -> Double {
            switch self {
            case .smooth: u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
            case .snappy: u < 0.5 ? 16 * pow(u, 5) : 1 - pow(-2 * u + 2, 5) / 2
            case .linear: u
            }
        }
    }

    /// The glowing edge on the cut.
    public enum Seam: String, CaseIterable, Sendable { case white, accent, off }

    /// Where the cut is `t` seconds after the fade started, or nil once it has
    /// slid off. `cutAt` is when the fade ended early, if it did.
    public static func cut(at t: Double, fade: Double, cutAt: Double? = nil,
                           sliceIn: Double = sliceInDefault, slideOut: Double = slideOutDefault,
                           hold: Hold = .half, easing: Easing = .smooth) -> Double? {
        let slideFrom = min(cutAt ?? fade, fade)
        if t < slideFrom { return held(at: t, fade: fade, sliceIn: sliceIn, hold: hold, easing: easing) }
        let s0 = held(at: slideFrom, fade: fade, sliceIn: sliceIn, hold: hold, easing: easing)
        // A cut still near the corner has less far to go, so it goes quicker.
        let length = slideOut * min(1, s0)
        guard length > 0.001 else { return nil }
        let u = (t - slideFrom) / length
        return u >= 1 ? nil : s0 * (1 - easing.out(u))
    }

    /// The seam's brightness, 0 to 1: bright while it moves in, settled while
    /// it holds, flaring then gone as it leaves.
    public static func seam(at t: Double, fade: Double, cutAt: Double? = nil,
                            sliceIn: Double = sliceInDefault, slideOut: Double = slideOutDefault,
                            hold: Hold = .half, easing: Easing = .smooth) -> Double {
        let slideFrom = min(cutAt ?? fade, fade)
        let into = hold == .sweep ? fade : min(sliceIn, fade)
        if t < slideFrom { return t < into ? 1 - 0.45 * max(0, t) / into : 0.55 }
        let s0 = held(at: slideFrom, fade: fade, sliceIn: sliceIn, hold: hold, easing: easing)
        let u = (t - slideFrom) / max(0.001, slideOut * min(1, s0))
        return u < 0.3 ? 0.55 + 0.45 * u / 0.3 : max(0, 1 - (u - 0.3) / 0.7)
    }

    static func held(at t: Double, fade: Double, sliceIn: Double, hold: Hold, easing: Easing) -> Double {
        if hold == .sweep {
            guard fade > 0 else { return 0 }
            return 2 - 2 * easing.out(min(1, max(0, t) / fade))
        }
        let into = min(sliceIn, fade)
        guard into > 0, t < into else { return hold.s }
        return 2 - (2 - hold.s) * easing.into(max(0, t) / into)
    }
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
