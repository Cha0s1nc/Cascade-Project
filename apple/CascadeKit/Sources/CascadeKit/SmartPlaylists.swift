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

        // The desktop's stored shape: {"field":"genre","op":"is","value":...},
        // {"field":"year","op":"between","min":..,"max":..}, and so on, so a
        // definition written by either app reads in the other. The first
        // version of this app wrote Swift's own enum encoding ({"genre":
        // {"_0":...}}); decoding still takes that, so an existing phone's
        // playlists survive the change.
        private enum Key: String, CodingKey { case field, op, value, min, max, days }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            guard let field = try c.decodeIfPresent(String.self, forKey: .field) else {
                self = try LegacyRule(from: decoder).rule
                return
            }
            let op = try c.decodeIfPresent(String.self, forKey: .op)
            func bad() -> DecodingError {
                .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad \(field) rule"))
            }
            func int(_ key: Key, _ fallback: Int) -> Int {
                if let n = try? c.decode(Int.self, forKey: key) { return n }
                if let d = try? c.decode(Double.self, forKey: key), d.isFinite { return Int(d) }
                return fallback
            }
            switch field {
            case "genre":
                guard op == "is" || op == "isNot", let v = try c.decodeIfPresent(String.self, forKey: .value) else { throw bad() }
                self = .genre(v, isNot: op == "isNot")
            case "artist":
                guard op == "is", let v = try c.decodeIfPresent(String.self, forKey: .value) else { throw bad() }
                self = .artist(v)
            case "year":
                guard op == "between" else { throw bad() }
                self = .year(min: int(.min, 1000), max: int(.max, 2100))
            case "addedWithinDays":
                guard op == "lte" else { throw bad() }
                self = .addedWithinDays(int(.days, 30))
            case "played":
                guard op == "is", let v = try? c.decode(Bool.self, forKey: .value) else { throw bad() }
                self = .played(v)
            case "playCount":
                guard op == "gte" else { throw bad() }
                self = .playCountAtLeast(int(.value, 1))
            case "favorite":
                guard op == "is", let v = try? c.decode(Bool.self, forKey: .value) else { throw bad() }
                self = .favorite(v)
            default: throw bad()
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case .genre(let g, let isNot):
                try c.encode("genre", forKey: .field); try c.encode(isNot ? "isNot" : "is", forKey: .op)
                try c.encode(g, forKey: .value)
            case .artist(let a):
                try c.encode("artist", forKey: .field); try c.encode("is", forKey: .op); try c.encode(a, forKey: .value)
            case .year(let lo, let hi):
                try c.encode("year", forKey: .field); try c.encode("between", forKey: .op)
                try c.encode(lo, forKey: .min); try c.encode(hi, forKey: .max)
            case .addedWithinDays(let d):
                try c.encode("addedWithinDays", forKey: .field); try c.encode("lte", forKey: .op)
                try c.encode(d, forKey: .days)
            case .played(let p):
                try c.encode("played", forKey: .field); try c.encode("is", forKey: .op); try c.encode(p, forKey: .value)
            case .playCountAtLeast(let n):
                try c.encode("playCount", forKey: .field); try c.encode("gte", forKey: .op); try c.encode(n, forKey: .value)
            case .favorite(let f):
                try c.encode("favorite", forKey: .field); try c.encode("is", forKey: .op); try c.encode(f, forKey: .value)
            }
        }
    }

    /// The rule as this app first stored it (Swift's synthesized enum coding),
    /// kept only to read definitions saved before the desktop's shape.
    private enum LegacyRule: Codable {
        case genre(String, isNot: Bool)
        case artist(String)
        case year(min: Int, max: Int)
        case addedWithinDays(Int)
        case played(Bool)
        case playCountAtLeast(Int)
        case favorite(Bool)

        var rule: Rule {
            switch self {
            case .genre(let g, let n): .genre(g, isNot: n)
            case .artist(let a): .artist(a)
            case .year(let a, let b): .year(min: a, max: b)
            case .addedWithinDays(let d): .addedWithinDays(d)
            case .played(let p): .played(p)
            case .playCountAtLeast(let n): .playCountAtLeast(n)
            case .favorite(let f): .favorite(f)
            }
        }
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

    // MARK: Coding
    //
    // The desktop's shape: {id, name, match: "all"|"any", rules, sortBy,
    // sortDir: "asc"|"desc", limit}. Reading also takes this app's first
    // shape (matchAny, descending), and an unreadable value falls back to the
    // default as the desktop's parser does, so one bad field never loses a
    // playlist. A bad rule is dropped, not the playlist.

    private enum Key: String, CodingKey { case id, name, match, rules, sortBy, sortDir, limit, matchAny, descending }

    private struct LossyRule: Decodable {
        let value: Rule?
        init(from decoder: Decoder) throws { value = try? Rule(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let match = try? c.decode(String.self, forKey: .match) {
            matchAny = match == "any"
        } else {
            matchAny = (try? c.decode(Bool.self, forKey: .matchAny)) ?? false
        }
        rules = ((try? c.decode([LossyRule].self, forKey: .rules)) ?? []).compactMap(\.value)
        sortBy = (try? c.decode(SortField.self, forKey: .sortBy)) ?? .name
        if let dir = try? c.decode(String.self, forKey: .sortDir) {
            descending = dir == "desc"
        } else {
            descending = (try? c.decode(Bool.self, forKey: .descending)) ?? false
        }
        if let n = try? c.decode(Int.self, forKey: .limit) {
            limit = n
        } else if let d = try? c.decode(Double.self, forKey: .limit), d.isFinite {
            limit = Int(d)
        } else {
            limit = 100
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(matchAny ? "any" : "all", forKey: .match)
        try c.encode(rules, forKey: .rules)
        try c.encode(sortBy, forKey: .sortBy)
        try c.encode(descending ? "desc" : "asc", forKey: .sortDir)
        try c.encode(limit, forKey: .limit)
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

    /// The list as `defaults` holds it, as Data (what this app writes) or as
    /// JSON text (what the desktop's store holds, so a settings import can
    /// copy the value across as it is).
    public static func stored(in defaults: UserDefaults, key: String = "cascade.smartPlaylists") -> [SmartPlaylist] {
        if let data = defaults.data(forKey: key) { return decodeList(data) }
        return decodeList(defaults.string(forKey: key)?.data(using: .utf8))
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
