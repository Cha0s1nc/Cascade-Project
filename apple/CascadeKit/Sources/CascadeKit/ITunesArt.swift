import Foundation

// Picking the right album out of an iTunes Search response, ported from src/core/itunes-art.ts.
//
// The search is a fuzzy text query, so the first hit is whatever Apple thought was most relevant
// to "artist album" as a phrase: often a tribute record, a karaoke version or a different artist's
// album. So candidates are matched against what was asked for, and nothing is returned when none
// fit. No art is a correct answer (Discord falls back to the app icon); someone else's art is not.

public struct ITunesResult: Sendable, Equatable, Decodable {
    public var collectionName: String?
    public var collectionArtistName: String?
    public var artistName: String?
    public var artworkUrl100: String?
    public var wrapperType: String?
    public var artistId: Int?

    public init(collectionName: String? = nil, collectionArtistName: String? = nil, artistName: String? = nil,
                artworkUrl100: String? = nil, wrapperType: String? = nil, artistId: Int? = nil) {
        self.collectionName = collectionName; self.collectionArtistName = collectionArtistName
        self.artistName = artistName; self.artworkUrl100 = artworkUrl100
        self.wrapperType = wrapperType; self.artistId = artistId
    }
}

/// Lowercase, unaccent, and reduce to alphanumeric words. "DAMN." and "Damn" are the same album.
private func clean(_ s: String) -> String {
    let stripped = String(String.UnicodeScalarView(
        s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36f).contains($0.value) }))
    var out = "", lastSpace = true
    for u in stripped.lowercased().unicodeScalars {
        let ok = (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
        if ok { out.unicodeScalars.append(u); lastSpace = false }
        else if !lastSpace { out.append(" "); lastSpace = true }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// `clean`, minus the edition furniture labels disagree about ("Kid A" against "Kid A (Deluxe
/// Edition)", or "- Single"). A looser match than `clean`, and scored lower.
private func base(_ s: String) -> String {
    clean(s.replacingOccurrences(of: #"\s*[(\[][^)\]]*[)\]]"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+-\s+(single|ep)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive]))
}

/// Whether two artist spellings plausibly name the same act. ponytail: substring match, not word
/// boundary; a false hit on a short name only adds a tiebreak point between albums that already
/// matched by name. Tighten it if it ever gates a decision on its own.
public func itunesArtistMatches(_ got: String, _ want: String) -> Bool {
    let w = base(want)
    if w.isEmpty { return true }
    let g = base(got)
    return !g.isEmpty && (g == w || g.contains(w) || w.contains(g))
}

/// The artwork URL for the best-matching album, upscaled from the 100px thumbnail, or nil if
/// nothing in `results` is plausibly the album asked for. Album name carries the decision, the
/// artist only breaks ties; with no album name the artist has to match on its own.
public func pickItunesArt(_ results: [ITunesResult]?, artist: String, album: String, size: Int = 600) -> String? {
    let wantAlbum = base(album), wantArtist = base(artist)
    var best: String?, bestScore = 0
    for r in results ?? [] {
        guard let url = r.artworkUrl100, !url.isEmpty else { continue }
        let name = r.collectionName ?? ""
        let by = r.collectionArtistName ?? r.artistName ?? ""
        let byArtist = itunesArtistMatches(by, wantArtist)
        let albumScore: Int
        if wantAlbum.isEmpty { albumScore = byArtist ? 1 : 0 }
        else if clean(name) == clean(album) { albumScore = 3 }
        else if base(name) == wantAlbum { albumScore = 2 }
        else { albumScore = 0 }
        if albumScore == 0 { continue }
        // Doubled so an artist tiebreak can never outrank a better album match.
        let score = albumScore * 2 + (byArtist ? 1 : 0)
        if score > bestScore { bestScore = score; best = url }
    }
    return best?.replacingOccurrences(of: #"\d+x\d+bb"#, with: "\(size)x\(size)bb", options: .regularExpression)
}

/// The outcome of waiting a bounded time for a cover.
public enum ArtWait: Sendable, Equatable {
    case found(String)
    /// iTunes answered and has nothing for this album: a real answer, never retried.
    case none
    /// The deadline beat the lookup; a cover may still be coming.
    case pending
}

/// Looks covers up on iTunes, cached per album. Public URLs only: the result is safe to hand to
/// Discord, unlike a Jellyfin image URL, which carries the token.
public actor ITunesArt {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)
    public static let shared = ITunesArt(fetch: ITunesArt.urlSessionFetch)

    private struct Lookup: Sendable { var url: String?; var cacheable: Bool }
    private let fetch: Fetch
    private let artMax = 1000, discogMax = 100
    private var arts: [String: Task<Lookup, Never>] = [:], artOrder: [String] = []
    private var discogs: [String: Task<[ITunesResult]?, Never>] = [:], discogOrder: [String] = []

    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    public static let urlSessionFetch: Fetch = { url in
        var req = URLRequest(url: url); req.timeoutInterval = 7
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// nil is "no art", including a lookup that failed (which is not remembered, so the next play asks again).
    public func art(artist: String, album: String) async -> String? {
        let key = "\(artist)|||\(album)".lowercased()
        let t: Task<Lookup, Never>
        if let existing = arts[key] {
            artOrder.removeAll { $0 == key }; artOrder.append(key)
            t = existing
        } else {
            if arts.count >= artMax, let oldest = artOrder.first { arts[oldest] = nil; artOrder.removeFirst() }
            t = Task { await self.lookup(artist: artist, album: album) }
            arts[key] = t; artOrder.append(key)
        }
        let r = await t.value
        if !r.cacheable, arts[key] == t { arts[key] = nil; artOrder.removeAll { $0 == key } }
        return r.url
    }

    /// The cover within `ms`, else `.pending`. The lookup keeps running and is shared with the next `art` call.
    public func art(artist: String, album: String, within ms: Int) async -> ArtWait {
        await withTaskGroup(of: ArtWait.self) { group in
            group.addTask { await self.art(artist: artist, album: album).map { .found($0) } ?? .none }
            group.addTask { try? await Task.sleep(for: .milliseconds(ms)); return .pending }
            let first = await group.next() ?? .pending
            group.cancelAll()
            return first
        }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? s
    }

    private func results(_ url: String) async throws -> [ITunesResult]? {
        guard let u = URL(string: url) else { return nil }
        let (data, status) = try await fetch(u)
        guard (200..<300).contains(status) else { return nil }
        struct Body: Decodable { var results: [ITunesResult]? }
        return try JSONDecoder().decode(Body.self, from: data).results ?? []
    }

    private func lookup(artist: String, album: String) async -> Lookup {
        do {
            let term = Self.encode("\(artist) \(album)".trimmingCharacters(in: .whitespaces))
            // A 403 (the unauthenticated search allows about 20 a minute) is not an answer about the album.
            guard let found = try await results("https://itunes.apple.com/search?term=\(term)&entity=album&limit=15&media=music") else {
                return Lookup(url: nil, cacheable: false)
            }
            var url = pickItunesArt(found, artist: artist, album: album)
            if url == nil, !artist.isEmpty, !album.isEmpty {
                url = pickItunesArt(await discography(artist), artist: artist, album: album)
            }
            return Lookup(url: url, cacheable: true)
        } catch {
            return Lookup(url: nil, cacheable: false)
        }
    }

    /// The artist's whole catalog, for when the search index missed the album. Cached per artist.
    private func discography(_ artist: String) async -> [ITunesResult] {
        let key = artist.lowercased()
        let t: Task<[ITunesResult]?, Never>
        if let existing = discogs[key] {
            discogOrder.removeAll { $0 == key }; discogOrder.append(key)
            t = existing
        } else {
            if discogs.count >= discogMax, let oldest = discogOrder.first { discogs[oldest] = nil; discogOrder.removeFirst() }
            t = Task { () -> [ITunesResult]? in
                do {
                    guard let hit = try await self.results("https://itunes.apple.com/search?term=\(Self.encode(artist))&entity=musicArtist&limit=1")?.first,
                          let id = hit.artistId, itunesArtistMatches(hit.artistName ?? "", artist) else { return [] }
                    guard let all = try await self.results("https://itunes.apple.com/lookup?id=\(id)&entity=album&limit=200") else { return nil }
                    return all.filter { $0.wrapperType == "collection" && $0.artworkUrl100 != nil }
                } catch { return nil }
            }
            discogs[key] = t; discogOrder.append(key)
        }
        if let r = await t.value { return r }
        if discogs[key] == t { discogs[key] = nil; discogOrder.removeAll { $0 == key } }
        return []
    }
}
