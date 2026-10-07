import Foundation

// Jellyfin Media Segments (10.10 and later): typed ranges inside a video, such
// as an intro or the end credits, that a player can offer to skip. The port of
// the desktop's src/core/media-segments.ts, with its tests.
//
// `GET /MediaSegments/{itemId}` answers `{ Items: [{ Id, ItemId, Type,
// StartTicks, EndTicks }], TotalRecordCount, StartIndex }`. The server only has
// data when a provider made it (the Intro Skipper plugin, chapter-based
// detection), so an older server (404) or an empty list both mean "show
// nothing", never an error.

public enum MediaSegmentType: String, Sendable, Equatable {
    case intro = "Intro"
    case outro = "Outro"
    case recap = "Recap"
    case preview = "Preview"
    case commercial = "Commercial"
}

/// A segment as the player uses it, in seconds.
public struct MediaSegment: Sendable, Equatable {
    public var type: MediaSegmentType
    public var startSeconds: Double
    public var endSeconds: Double

    public init(type: MediaSegmentType, startSeconds: Double, endSeconds: Double) {
        self.type = type
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// Only intros and outros get a button. A recap or a commercial has no
    /// agreed meaning for "skip", so they are parsed and left alone.
    public var isSkippable: Bool { type == .intro || type == .outro }

    /// "Skip Intro", "Skip Credits".
    public var skipLabel: String { type == .outro ? "Skip Credits" : "Skip Intro" }
}

/// What skipping does.
public enum SkipAction: Sendable, Equatable {
    case seek(Double)
    /// An outro that runs to the end: go on to the next episode, or stop.
    case next
}

public enum MediaSegments {
    /// Within this many seconds of the end counts as "runs to the end".
    public static let endSlackSeconds = 1.0

    private struct Response: Decodable { var items: [Raw]? }
    private struct Raw: Decodable {
        var type: String?
        var startTicks: Double?
        var endTicks: Double?
    }

    /// The segment list out of a `/MediaSegments/{id}` body, sorted by start.
    /// Anything malformed (a type this build does not know, a negative or
    /// non-finite tick, an end that is not after its start) is dropped rather
    /// than trusted: the body comes from a server plugin. A body that is not
    /// the expected shape at all is no segments.
    public static func parse(_ data: Data) -> [MediaSegment] {
        guard let response = try? JSON.decoder.decode(Response.self, from: data) else { return [] }
        var out: [MediaSegment] = []
        for raw in response.items ?? [] {
            guard let name = raw.type, let type = MediaSegmentType(rawValue: name),
                  let start = raw.startTicks, let end = raw.endTicks,
                  start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            out.append(MediaSegment(type: type,
                                    startSeconds: start / 10_000_000,
                                    endSeconds: end / 10_000_000))
        }
        return out.sorted {
            $0.startSeconds != $1.startSeconds ? $0.startSeconds < $1.startSeconds : $0.endSeconds < $1.endSeconds
        }
    }

    /// The skippable segment playing at `seconds`, or nil. The start is inside
    /// it and the end is not, so a skip that lands exactly on the end does not
    /// offer the button again. Where segments overlap, the one that ends last
    /// wins, so one skip leaves all of them.
    public static func active(in segments: [MediaSegment], at seconds: Double) -> MediaSegment? {
        guard seconds.isFinite else { return nil }
        var best: MediaSegment?
        for s in segments where s.isSkippable && seconds >= s.startSeconds && seconds < s.endSeconds {
            if best == nil || s.endSeconds > best!.endSeconds { best = s }
        }
        return best
    }

    /// What skipping `segment` does in an item `duration` seconds long. An
    /// unknown duration (0) never counts as the end.
    public static func skipAction(for segment: MediaSegment, duration: Double) -> SkipAction {
        let toTheEnd = segment.type == .outro && duration > 0 && segment.endSeconds >= duration - endSlackSeconds
        return toTheEnd ? .next : .seek(segment.endSeconds)
    }
}

public extension JellyfinClient {
    /// The item's segments, or none: a server without the endpoint (404), with
    /// no provider, or any other failure shows no button rather than an error.
    func mediaSegments(for itemId: String) async -> [MediaSegment] {
        guard let data = try? await getData("/MediaSegments/\(itemId)") else { return [] }
        return MediaSegments.parse(data)
    }
}
