import Foundation

// Chapters, ported from playback.ts (chapterList, chapterAt, chapterTarget):
// the ticks on the scrubber, the chapter list and the previous/next chapter
// keys all read from this.

/// A chapter as the player uses it: where it starts, in seconds, and what to
/// call it.
public struct Chapter: Sendable, Equatable {
    public var sec: Double
    public var name: String

    public init(sec: Double, name: String) {
        self.sec = sec
        self.name = name
    }
}

/// Jellyfin's `Chapters` entry, as sent. Only what the player reads.
public struct RawChapter: Decodable, Sendable {
    public var startPositionTicks: Int?
    public var name: String?

    public init(startPositionTicks: Int? = nil, name: String? = nil) {
        self.startPositionTicks = startPositionTicks
        self.name = name
    }
}

/// Jellyfin's chapters cleaned up for seeking: sorted, deduplicated by start,
/// anything past the end of the item dropped, and a name for the ones that
/// have none. Fewer than two leaves nothing worth offering, since one chapter
/// is just "the film".
public func chapterList(_ raw: [RawChapter]?, runTimeTicks: Int? = nil) -> [Chapter] {
    var seen = Set<Int>()
    let list = (raw ?? [])
        .compactMap { c -> (ticks: Int, name: String?)? in
            guard let t = c.startPositionTicks, t >= 0 else { return nil }
            if let total = runTimeTicks, total > 0, t >= total { return nil }
            return (t, c.name)
        }
        .sorted { $0.ticks < $1.ticks }
        .filter { seen.insert($0.ticks).inserted }
        .enumerated()
        .map { i, c -> Chapter in
            let name = c.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Chapter(sec: seconds(fromTicks: c.ticks), name: name.isEmpty ? "Chapter \(i + 1)" : name)
        }
    return list.count > 1 ? list : []
}

/// Index of the chapter playing at `sec`, or -1 before the first one.
public func chapterAt(_ chapters: [Chapter], _ sec: Double) -> Int {
    var at = -1
    for (i, c) in chapters.enumerated() {
        if c.sec > sec { break }
        at = i
    }
    return at
}

/// Where a chapter jump from `sec` lands, in seconds, or nil for nowhere to go.
///
/// Forward is the next chapter's start. Back works like a CD player's
/// previous button (and YouTube's): more than `restartWithin` seconds into a
/// chapter goes to its own start, closer than that goes to the chapter before.
public func chapterTarget(_ chapters: [Chapter], _ sec: Double, forward: Bool, restartWithin: Double = 3) -> Double? {
    let cur = chapterAt(chapters, sec)
    if forward { return chapters.indices.contains(cur + 1) ? chapters[cur + 1].sec : nil }
    if cur < 0 { return nil }
    if sec - chapters[cur].sec > restartWithin { return chapters[cur].sec }
    return chapters.indices.contains(cur - 1) ? chapters[cur - 1].sec : chapters[cur].sec
}

public extension JellyfinClient {
    /// A movie or episode's chapters. The list calls leave them out, and the
    /// single-item route has no `fields` parameter: it returns Chapters on
    /// its own (checked against 10.11.11's spec and a real item). A failure
    /// is no chapters: they are a nicety, never a reason to stop a film.
    func chapters(of item: JfItem) async -> [Chapter] {
        struct Response: Decodable { var chapters: [RawChapter]? }
        guard let r: Response = try? await get("/Items/\(item.id)", params: ["userId": currentConfig.userId]) else { return [] }
        return chapterList(r.chapters, runTimeTicks: item.runTimeTicks)
    }
}
