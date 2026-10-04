import Foundation

// The pure half of the video player's keys and pickers, ported from
// renderer.js (VIDEO_KEYS, skipBy, setVideoRate, toggleSubtitles): what each
// key does to a number, so the view only has to feed it and apply the answer.

public enum VideoControls {
    /// Seconds for J and L, and the buttons.
    public static let skipSeconds = 10.0
    /// Seconds for the arrow keys.
    public static let arrowSeconds = 5.0
    /// Volume step for Up and Down, as a fraction of full.
    public static let volumeStep: Float = 0.05
    /// A run of skips on a transcode is sent once, this long after the last
    /// one: every landing is a new encode, and the server was still starting
    /// the first when the fifth arrived.
    public static let skipBatchDelay = 0.35

    public static let rates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Where a skip lands, kept inside the item.
    public static func skipTarget(from base: Double, by delta: Double, duration: Double) -> Double {
        max(0, min(duration > 0 ? duration : .infinity, base + delta))
    }

    /// The 0-9 keys: 0% to 90% of the item.
    public static func tenthTarget(_ digit: Int, duration: Double) -> Double? {
        guard (0...9).contains(digit), duration > 0 else { return nil }
        return duration * Double(digit) / 10
    }

    /// The speed after < or >, stopping at the ends of the list. A rate that
    /// is not on the list (set elsewhere) steps from 1x, as the desktop does.
    public static func nextRate(from current: Double, faster: Bool) -> Double {
        let i = rates.firstIndex(of: current) ?? 3
        return rates[max(0, min(rates.count - 1, i + (faster ? 1 : -1)))]
    }

    /// "1x", "0.75x", "1.25x".
    public static func rateLabel(_ rate: Double) -> String {
        (rate == rate.rounded() ? String(Int(rate)) : String(rate)) + "x"
    }

    /// A frame's length: the film's own rate when the server told us it,
    /// otherwise a film's usual.
    public static func frameDuration(fps: Double?) -> Double {
        1 / ((fps ?? 0) > 1 ? fps! : 24)
    }

    /// "1:05:09" or "5:09".
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// The keys panel (`?`), as the desktop lists them. `chapterKeys` is the
    /// Option pair on a Mac.
    public static let shortcuts: [(keys: String, what: String)] = [
        ("Space  or  K", "Play or pause"),
        ("J  /  L", "Back or forward 10 seconds"),
        ("\u{2190}  /  \u{2192}", "Back or forward 5 seconds"),
        ("\u{2191}  /  \u{2193}", "Volume up or down"),
        ("M", "Mute"),
        ("F", "Fullscreen"),
        ("C", "Subtitles on or off"),
        ("0 \u{2013} 9", "Jump to 0% \u{2013} 90%"),
        ("Home  /  End", "Start or end"),
        (",  /  .", "Previous or next frame (while paused)"),
        ("<  /  >", "Slower or faster"),
        ("Shift+P  /  Shift+N", "Previous or next episode"),
        ("\u{2325}\u{2190}  /  \u{2325}\u{2192}", "Previous or next chapter"),
        ("?", "This list"),
        ("Esc", "Close"),
    ]
}

/// One subtitle option the player offers, in the order they were found.
public struct SubtitleChoice: Sendable, Equatable, Identifiable {
    /// Position in the order found, which the player maps back to its option.
    public var id: Int
    public var label: String
    public var isDefault: Bool
    public var isForced: Bool

    public init(id: Int, label: String, isDefault: Bool = false, isForced: Bool = false) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

/// The picker's order: the default track first, then forced ones, then the
/// rest as found. Stable, so equal tracks keep the server's order.
public func orderedSubtitles(_ choices: [SubtitleChoice]) -> [SubtitleChoice] {
    func rank(_ c: SubtitleChoice) -> Int { c.isDefault ? 0 : c.isForced ? 1 : 2 }
    return choices.enumerated().sorted {
        let (a, b) = (rank($0.element), rank($1.element))
        return a != b ? a < b : $0.offset < $1.offset
    }.map(\.element)
}

/// What C does: with a track showing it turns subtitles off and remembers
/// which; with none showing it brings back the remembered one, so on/off
/// returns to your pick rather than to the default. `remembered` is a
/// `SubtitleChoice.id`, clamped to `count` tracks. Nil when there is nothing
/// to choose from.
public func toggledSubtitle(showing: Int?, remembered: Int, count: Int) -> (selection: Int?, remembered: Int)? {
    guard count > 0 else { return nil }
    if let showing { return (nil, showing) }
    return (min(max(remembered, 0), count - 1), remembered)
}
