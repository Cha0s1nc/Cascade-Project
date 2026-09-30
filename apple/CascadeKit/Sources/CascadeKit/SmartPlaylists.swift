import Foundation

/// A playlist made of rules rather than songs: the desktop's smart playlists
/// (src/core/smart-playlist.ts). Jellyfin has no such thing, so definitions
/// live on this device, validated whenever they are read back, since a stored
/// value is untrusted.
///
/// Evaluation is split on purpose, as on the desktop: `query` pushes what it
/// can to the server as a prefilter (a superset of the matches, never the
/// answer), and `matches` checks every rule against every song, always. A
/// rule the server cannot express is slower, never wrong.
public struct SmartPlaylist: Codable, Hashable, Identifiable, Sendable {
    public enum Rule: Codable, Hashable, Sendable {
        case genre(String, isNot: Bool)
        case artist(String)
        case year(min: Int, max: Int)
        case addedWithinDays(Int)
        case played(Bool)
        case playCountAtLeast(Int)
        case favorite(Bool)
    }

    public enum SortField: String, Codable, CaseIterable, Sendable {
        case name, artist, album, dateAdded, playCount
    }

    public var id: String
    public var name: String
    /// Any rule rather than all of them.
    public var matchAny = false
    public var rules: [Rule] = []
    public var sortBy: SortField = .name
    public var descending = false
    public var limit = 100

    public static let maxLimit = 500

    public init(id: String = "user:\(UUID().uuidString)", name: String, matchAny: Bool = false,
                rules: [Rule] = [], sortBy: SortField = .name, descending: Bool = false, limit: Int = 100) {
        self.id = id
        self.name = name
        self.matchAny = matchAny
        self.rules = rules
        self.sortBy = sortBy
        self.descending = descending
        self.limit = limit
    }

    // MARK: Storage

    /// What was stored, each definition checked and clamped. A corrupt list
    /// is no list, and a bad entry is dropped, rather than either breaking
    /// the Playlists screen.
    public static func decodeList(_ data: Data?) -> [SmartPlaylist] {
        struct Lossy: Decodable {
            let value: SmartPlaylist?
            init(from decoder: Decoder) throws { value = try? SmartPlaylist(from: decoder) }
        }
        guard let data, let list = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return list.compactMap { $0.value?.validated() }
    }

    public static func encodeList(_ list: [SmartPlaylist]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
    }

    /// Nil without an id and a name; otherwise every value in range.
    public func validated() -> SmartPlaylist? {
        var out = self
        out.id = id.trimmingCharacters(in: .whitespaces)
        out.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.id.isEmpty, !out.name.isEmpty else { return nil }
        out.limit = min(Self.maxLimit, max(1, limit))
        out.rules = rules.compactMap { rule in
            switch rule {
            case .genre(let g, let isNot):
                let g = g.trimmingCharacters(in: .whitespaces)
                return g.isEmpty ? nil : .genre(g, isNot: isNot)
            case .artist(let a):
                let a = a.trimmingCharacters(in: .whitespaces)
                return a.isEmpty ? nil : .artist(a)
            case .year(let a, let b):
                let (a, b) = (min(2100, max(1000, a)), min(2100, max(1000, b)))
                return .year(min: Swift.min(a, b), max: Swift.max(a, b))
            case .addedWithinDays(let d): return .addedWithinDays(min(3650, max(1, d)))
            case .playCountAtLeast(let n): return .playCountAtLeast(min(1_000_000, max(0, n)))
            case .played, .favorite: return rule
            }
        }
        return out
    }

    // MARK: Evaluation

    /// The server prefilter, for an all-match only: an any-match cannot be
    /// one query (each parameter ANDs with the rest). Only the first rule of
    /// each kind is pushed: a second "genre is" must stay an AND, and
    /// Jellyfin ORs the values of one parameter. A year range over a century
    /// is left to the client rather than built into a huge query string.
    public var query: [String: String] {
        guard !matchAny else { return [:] }
        var out: [String: String] = [:]
        for rule in rules {
            switch rule {
            case .genre(let g, false) where out["genres"] == nil: out["genres"] = g
            case .artist(let a) where out["artists"] == nil: out["artists"] = a
            case .year(let a, let b) where out["years"] == nil && b - a <= 100:
                out["years"] = (a...b).map(String.init).joined(separator: ",")
            case .played(let p) where out["isPlayed"] == nil: out["isPlayed"] = p ? "true" : "false"
            case .favorite(let f) where out["isFavorite"] == nil: out["isFavorite"] = f ? "true" : "false"
            default: break
            }
        }
        return out
    }

    public static func ruleMatches(_ rule: Rule, _ item: JfItem, now: Date) -> Bool {
        switch rule {
        case .genre(let g, let isNot):
            let has = (item.genres ?? []).contains { $0.caseInsensitiveCompare(g) == .orderedSame }
            return isNot ? !has : has
        case .artist(let a):
            return (item.artists ?? []).contains { $0.caseInsensitiveCompare(a) == .orderedSame }
                || (item.albumArtist ?? "").caseInsensitiveCompare(a) == .orderedSame
        case .year(let a, let b):
            guard let y = item.productionYear else { return false }
            return (a...b).contains(y)
        case .addedWithinDays(let days):
            guard let created = PlayHistory.date(item.dateCreated) else { return false }
            return now.timeIntervalSince(created) <= Double(days) * 86_400
        case .played(let p): return (item.userData?.played ?? false) == p
        case .playCountAtLeast(let n): return (item.userData?.playCount ?? 0) >= n
        case .favorite(let f): return (item.userData?.isFavorite ?? false) == f
        }
    }

    /// No rules matches everything: "all my music, sorted my way" is a fair
    /// use of the builder, not a state to special-case.
    public func matches(_ item: JfItem, now: Date) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAny ? rules.contains { Self.ruleMatches($0, item, now: now) }
            : rules.allSatisfy { Self.ruleMatches($0, item, now: now) }
    }

    /// The playlist itself: every rule checked, sorted, capped. Ties keep the
    /// server's order.
    public func apply(_ items: [JfItem], now: Date) -> [JfItem] {
        let kept = items.enumerated().filter { matches($0.element, now: now) }
        let sorted = kept.sorted { a, b in
            let order = compare(a.element, b.element)
            if order == .orderedSame { return a.offset < b.offset }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return sorted.prefix(limit).map(\.element)
    }

    private func compare(_ a: JfItem, _ b: JfItem) -> ComparisonResult {
        func text(_ s: String?) -> String { (s ?? "").lowercased() }
        switch sortBy {
        // The title, not SortName: a song's SortName starts with its track
        // number, so "by name" interleaved albums (Overdrive 1, Unplugged 1,
        // Overdrive 2). The desktop sorts on SortName and does the same.
        case .name: return (a.name ?? "").localizedStandardCompare(b.name ?? "")
        case .artist: return text(a.albumArtist ?? a.artists?.first).compare(text(b.albumArtist ?? b.artists?.first))
        case .album: return text(a.album).compare(text(b.album))
        case .dateAdded:
            let (x, y) = (PlayHistory.date(a.dateCreated) ?? .distantPast, PlayHistory.date(b.dateCreated) ?? .distantPast)
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case .playCount:
            let (x, y) = (a.userData?.playCount ?? 0, b.userData?.playCount ?? 0)
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
    }
}

public extension JellyfinClient {
    private var smartFields: String { "Genres,DateCreated,SortName,ProductionYear" }

    /// Built in: every favorite song, by name.
    func favoriteSongs() async throws -> [JfItem] {
        try await itemsAcrossLibraries([
            "userId": currentConfig.userId, "recursive": "true", "includeItemTypes": "Audio",
            "filters": "IsFavorite", "sortBy": "SortName", "sortOrder": "Ascending",
        ])
    }

    /// Built in: the hundred songs played most. Each library's own top 200,
    /// then merged and cut, since a per-library cap alone could miss some of
    /// the true top 100 across libraries.
    func mostPlayedSongs(limit: Int = 100) async throws -> [JfItem] {
        let songs = try await itemsAcrossLibraries([
            "userId": currentConfig.userId, "recursive": "true", "includeItemTypes": "Audio",
            "sortBy": "PlayCount", "sortOrder": "Descending", "limit": "200",
        ])
        return Array(songs.filter { ($0.userData?.playCount ?? 0) > 0 }
            .sorted { ($0.userData?.playCount ?? 0) > ($1.userData?.playCount ?? 0) }
            .prefix(limit))
    }

    /// A user playlist's songs: the prefilter query, then every rule.
    func songs(matching playlist: SmartPlaylist, now: Date = .now) async throws -> [JfItem] {
        var params: [String: String?] = [
            "userId": currentConfig.userId, "recursive": "true", "includeItemTypes": "Audio",
            "sortBy": "SortName", "fields": smartFields,
        ]
        for (key, value) in playlist.query { params[key] = value }
        return playlist.apply(try await itemsAcrossLibraries(params), now: now)
    }
}
