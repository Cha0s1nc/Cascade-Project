import Foundation

// A video's chapters, for AVPlayerViewController's navigation markers. The
// desktop's chapterList (src/core/playback.ts) with its tests.
//
// Jellyfin's item carries them in `Chapters` when asked for with
// Fields=Chapters; the list queries do not ask, so they are fetched once per
// video, the way the desktop does.

/// One entry of Jellyfin's Chapters array.
public struct JfChapter: Codable, Sendable, Equatable {
    public var name: String?
    public var startPositionTicks: Int?

    public init(name: String? = nil, startPositionTicks: Int? = nil) {
        self.name = name
        self.startPositionTicks = startPositionTicks
    }
}

/// A chapter as the player uses it: where it starts, in seconds, and what to
/// call it.
public struct Chapter: Sendable, Equatable {
    public var startSeconds: Double
    public var name: String

    public init(startSeconds: Double, name: String) {
        self.startSeconds = startSeconds
        self.name = name
    }
}

public enum Chapters {
    /// Jellyfin's Chapters array, cleaned up: sorted, deduplicated by start,
    /// anything at or past the end of the item dropped, and a name for the ones
    /// that have none. Fewer than two leaves nothing worth offering, since one
    /// chapter is just "the film".
    public static func list(_ raw: [JfChapter]?, runTimeTicks: Int? = nil) -> [Chapter] {
        var seen = Set<Int>()
        let kept = (raw ?? [])
            .compactMap { c -> (ticks: Int, name: String?)? in
                guard let ticks = c.startPositionTicks, ticks >= 0 else { return nil }
                if let end = runTimeTicks, end > 0, ticks >= end { return nil }
                return (ticks, c.name)
            }
            .sorted { $0.ticks < $1.ticks }
            .filter { seen.insert($0.ticks).inserted }
        guard kept.count > 1 else { return [] }
        return kept.enumerated().map { i, c in
            let name = c.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Chapter(startSeconds: Double(c.ticks) / ticksPerSecond, name: name.isEmpty ? "Chapter \(i + 1)" : name)
        }
    }

    /// The chapters on the player's own timeline. A transcode's clock starts
    /// where it was asked to, so a chapter before that point is not in the
    /// stream, and the rest move back by it. (A direct file starts at 0.)
    public static func onPlayerTimeline(_ chapters: [Chapter], streamStartSeconds: Double) -> [Chapter] {
        guard streamStartSeconds > 0 else { return chapters }
        return chapters.filter { $0.startSeconds >= streamStartSeconds }
            .map { Chapter(startSeconds: $0.startSeconds - streamStartSeconds, name: $0.name) }
    }
}

public extension JellyfinClient {
    /// The video's chapters, or none: a film without any, or a request that
    /// failed, shows no markers rather than an error.
    func chapters(for item: JfItem) async -> [Chapter] {
        struct Response: Decodable { var chapters: [JfChapter]? }
        guard let r: Response = try? await get("/Users/\(currentConfig.userId)/Items/\(item.id)", params: ["fields": "Chapters"]) else {
            return []
        }
        return Chapters.list(r.chapters, runTimeTicks: item.runTimeTicks)
    }
}
