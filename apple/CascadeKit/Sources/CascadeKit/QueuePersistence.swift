import Foundation

// The queue as kept across a restart: the save and restore half of the
// desktop's src/core/queue.ts. Item ids rather than items (refetched on
// restore, so a track deleted meanwhile just drops out), where playback was,
// and the original order when shuffled. Music only: a video or a radio
// station is not kept, and an empty queue keeps nothing.
//
// Stored data is untrusted, so the readers take whatever JSONSerialization
// produced and check it field by field, as the TypeScript does: one bad field
// costs that field, not the whole queue.

/// The `cascade.lastQueue` default: the desktop's `lastQueue` store key, which
/// holds this as a JSON string.
public let lastQueueKey = "cascade.lastQueue"

public struct SavedQueue: Codable, Sendable, Equatable {
    public var ids: [String]
    public var index: Int
    public var positionSec: Double
    public var unshuffledIds: [String]?

    /// The same JSON the desktop writes: keys ids, index, positionSec and,
    /// only when shuffled, unshuffledIds. Sorted keys, so an unchanged queue
    /// is an identical string and the periodic save can skip writing it.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// More than this and a window around the current track is kept.
public let savedQueueMax = 2000

/// What to keep of a queue, or nil when there is nothing worth keeping: no
/// current track, or one that is not music.
public func savedQueueOf(_ queue: [JfItem], index: Int, positionSec: Double,
                         unshuffled: [JfItem] = []) -> SavedQueue? {
    guard queue.indices.contains(index), queue[index].type == "Audio" else { return nil }
    // Past the cap, a window that holds the current track.
    let start = queue.count > savedQueueMax
        ? max(0, min(index - 100, queue.count - savedQueueMax)) : 0
    let ids = queue[start..<min(queue.count, start + savedQueueMax)].map(\.id)
    let position = positionSec.isFinite ? max(0, (positionSec * 10).rounded() / 10) : 0
    return SavedQueue(ids: ids, index: index - start, positionSec: position,
                      unshuffledIds: unshuffled.isEmpty ? nil : unshuffled.prefix(savedQueueMax).map(\.id))
}

/// A stored queue's JSON text, parsed. Nil for text that is not JSON at all.
public func parseSavedQueue(_ text: String?) -> Any? {
    guard let text, let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

/// Jellyfin ids as they are on the wire: 32 hex digits, or a dashed GUID.
/// Checked because the ids go into a request, from a file anyone can edit.
private func isItemId(_ s: String) -> Bool {
    (32...36).contains(s.utf8.count) && s.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) || $0 == 0x2D
    }
}

private func idList(_ v: Any?) -> [String] {
    guard let array = v as? [Any] else { return [] }
    return Array(array.compactMap { ($0 as? String).flatMap { isItemId($0) ? $0 : nil } }.prefix(savedQueueMax))
}

/// A JSON number that is a whole number. Never a boolean, which Foundation
/// would otherwise hand back as 0 or 1.
private func wholeNumber(_ v: Any?) -> Int? {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    let d = n.doubleValue
    return d.isFinite && d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
}

/// Every id a stored queue needs fetched, or none if it is not a queue.
public func savedQueueIds(_ saved: Any?) -> [String] {
    guard let s = saved as? [String: Any] else { return [] }
    var seen = Set<String>()
    return (idList(s["ids"]) + idList(s["unshuffledIds"])).filter { seen.insert($0).inserted }
}

public struct RestoredQueue: Sendable {
    public var queue: [JfItem]
    public var index: Int
    public var positionSec: Double
    public var unshuffled: [JfItem]
}

/// Rebuilds a stored queue from freshly fetched items (any order). If the
/// current track is gone, the next one still there becomes current, from its
/// start.
public func restoreQueue(_ saved: Any?, items: [JfItem]) -> RestoredQueue? {
    guard let s = saved as? [String: Any] else { return nil }
    let ids = idList(s["ids"])
    let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let queue = ids.compactMap { byId[$0] }
    guard !queue.isEmpty else { return nil }
    let savedIndex = wholeNumber(s["index"]).map { min(max($0, 0), ids.count - 1) } ?? 0
    let position = (s["positionSec"] as? NSNumber).flatMap { n -> Double? in
        CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite ? max(0, n.doubleValue) : nil
    } ?? 0
    let stillThere = byId[ids[savedIndex]] != nil
    // Items kept before the saved current one: where it, or its successor, now sits.
    let before = ids[..<savedIndex].filter { byId[$0] != nil }.count
    return RestoredQueue(queue: queue, index: min(before, queue.count - 1),
                         positionSec: stillThere ? position : 0,
                         unshuffled: idList(s["unshuffledIds"]).compactMap { byId[$0] })
}

public extension JellyfinClient {
    /// The items for a stored queue, with the fields a track list asks for (see
    /// Library.swift) plus the sources merging reads.
    func restoredItems(ids: [String]) async throws -> [JfItem] {
        guard !ids.isEmpty else { return [] }
        // The ids go in the query string, 2000 of them is far past a URL's
        // reasonable length, so fetch in chunks.
        var all: [JfItem] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(ids.count, start + 100)])
            let response: JfItemsResponse = try await get("/Items", params: [
                "userId": currentConfig.userId, "ids": chunk.joined(separator: ","),
                "fields": "DateCreated,PrimaryImageAspectRatio,MediaSources",
            ])
            all += response.items ?? []
        }
        return all
    }
}
