import Foundation

// Lyric translations kept on disk between sessions, a port of
// src/core/translation-cache.ts. An entry is (key, english, translatedAt in ms), and
// the key is "engine|language|line". Entries expire 25 days after they were
// translated, the same limit the Cascade Server plugin keeps SpicyLyrics lyrics under:
// a translation is derived from the lyric text, so it is held no longer. Reading an
// entry does not extend it. The file is `[[key, text, at], ...]`, oldest first, the
// shape the desktop writes.

public struct TranslationCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var text: String
        /// Milliseconds since 1970.
        public var at: Double
    }

    public static let ttlMs: Double = 25 * 24 * 60 * 60 * 1000
    public static let maxEntries = 5000

    /// Past its limit, or stamped in the future (a clock that was wrong is not to be trusted).
    public static func expired(at: Double, now: Double) -> Bool {
        !(now - at < ttlMs) || at > now + 60_000
    }

    public static func key(language: String, line: String, engine: String = "apple") -> String {
        "\(engine)|\(language)|\(line)"
    }

    private struct Stored { var text: String; var at: Double; var stamp: Int }
    private var entries: [String: Stored] = [:]
    /// Least recently used goes first; a lookup or a store moves an entry to the end.
    private var clock = 0
    public private(set) var isDirty = false

    public init() {}

    /// From what was read off disk (untrusted: hand-edited or from an older build): malformed
    /// and expired entries dropped, the newest `max` kept in their original order.
    public init(raw: Any?, now: Double = Date().timeIntervalSince1970 * 1000, max: Int = TranslationCache.maxEntries) {
        for entry in Self.liveEntries(raw, now: now, max: max) { insert(entry) }
        isDirty = false
    }

    public static func liveEntries(_ raw: Any?, now: Double, max: Int = TranslationCache.maxEntries) -> [Entry] {
        guard let list = raw as? [Any] else { return [] }
        let ok: [Entry] = list.compactMap { item in
            guard let e = item as? [Any], e.count == 3,
                  let key = e[0] as? String, !key.isEmpty, key.count <= 4000,
                  let text = e[1] as? String, text.count <= 4000,
                  let at = (e[2] as? NSNumber)?.doubleValue, at.isFinite,
                  !expired(at: at, now: now) else { return nil }
            return Entry(key: key, text: text, at: at)
        }
        return Array(ok.suffix(max))
    }

    public var count: Int { entries.count }

    /// A remembered line, or nil if never seen or expired (an expired one is dropped).
    public mutating func lookup(_ key: String, now: Double = Date().timeIntervalSince1970 * 1000) -> String? {
        guard var hit = entries[key] else { return nil }
        if Self.expired(at: hit.at, now: now) {
            entries[key] = nil
            isDirty = true
            return nil
        }
        clock += 1
        hit.stamp = clock
        entries[key] = hit
        return hit.text
    }

    public mutating func store(_ key: String, _ text: String, now: Double = Date().timeIntervalSince1970 * 1000,
                               max: Int = TranslationCache.maxEntries) {
        insert(Entry(key: key, text: text, at: now))
        isDirty = true
        while entries.count > max, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            entries[oldest] = nil
        }
    }

    private mutating func insert(_ entry: Entry) {
        clock += 1
        entries[entry.key] = Stored(text: entry.text, at: entry.at, stamp: clock)
    }

    // MARK: Disk

    /// The live entries as the desktop's file, least recently used first.
    public func serialized(now: Double = Date().timeIntervalSince1970 * 1000) -> Data {
        let live = entries.filter { !Self.expired(at: $0.value.at, now: now) }
            .sorted { $0.value.stamp < $1.value.stamp }
            .map { [$0.key, $0.value.text, $0.value.at] as [Any] }
        return (try? JSONSerialization.data(withJSONObject: live)) ?? Data("[]".utf8)
    }

    public static func load(from url: URL, now: Double = Date().timeIntervalSince1970 * 1000) -> TranslationCache {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return TranslationCache() }
        var cache = TranslationCache(raw: raw, now: now)
        // Expired ones left the memory copy on load and must leave the disk too.
        if let list = raw as? [Any], list.count != cache.count { cache.isDirty = true }
        return cache
    }

    /// Written atomically, so a crash mid-write leaves the old file rather than half of one.
    public func save(to url: URL, now: Double = Date().timeIntervalSince1970 * 1000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialized(now: now).write(to: url, options: .atomic)
    }
}
