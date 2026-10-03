import Foundation

/// The most the server may stream, as a user picks it in Settings. The same
/// steps as the desktop's Max streaming bitrate, plus 256 kbps.
///
/// Anything below the source's bitrate makes the server transcode to AAC at
/// that rate (the device profile's HLS transcode), which is the point on a
/// metered connection. Original means the device profile's own ceiling, which
/// every file in a music library sits under, so it never transcodes for rate.
public enum StreamingQuality: Int, CaseIterable, Sendable, Identifiable {
    case original = 0
    case kbps320 = 320_000
    case kbps256 = 256_000
    case kbps192 = 192_000
    case kbps128 = 128_000
    case kbps96 = 96_000

    public var id: Int { rawValue }

    /// Bits per second to ask for, or nil to leave the profile's own limit.
    public var bitrate: Int? { self == .original ? nil : rawValue }

    public var label: String {
        self == .original ? "Original" : "\(rawValue / 1000) kbps"
    }

    /// A stored value is untrusted: an old build, a hand-edited plist or a
    /// bad write must land on a real step, never reach the server as a
    /// made-up bitrate.
    public init(stored: Any?) {
        self = (stored as? Int).flatMap(StreamingQuality.init(rawValue:)) ?? .original
    }

    /// The desktop's `maxStreamingBitrate`, a bits-per-second number with
    /// 140,000,000 as "Original" (its steps are 320/192/128/96 kbps). A value
    /// between two steps lands on the step below it, so a cap is never loosened
    /// by the mapping; anything at or past the desktop's Original, and anything
    /// unusable, is Original.
    public init(electronBitrate value: Any?) {
        let number = (value as? Int) ?? (value as? String).flatMap(Int.init) ?? 0
        guard number > 0, number < StreamingQuality.desktopOriginal else { self = .original; return }
        self = StreamingQuality.allCases.filter { $0.bitrate != nil && $0.rawValue <= number }
            .max { $0.rawValue < $1.rawValue } ?? .kbps96
    }

    /// The desktop's "Original" (src/core/jellyfin.ts DEFAULT_MAX_BITRATE).
    public static let desktopOriginal = 140_000_000

    public static let wifiKey = "cascade.streamingQuality"
    public static let cellularKey = "cascade.cellularStreamingQuality"
}

public extension DeviceProfile {
    /// This profile capped at `quality`. The cap goes in the profile as well
    /// as the request, since the server reads both.
    func capped(at quality: StreamingQuality) -> DeviceProfile {
        guard let bitrate = quality.bitrate else { return self }
        var copy = self
        copy.maxStreamingBitrate = min(bitrate, maxStreamingBitrate ?? bitrate)
        return copy
    }
}
