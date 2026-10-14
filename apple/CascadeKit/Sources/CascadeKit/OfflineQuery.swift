import Foundation

// The offline stand-in for the server: a request (path plus params) answered
// from the catalog (OfflineIndex) in Jellyfin's response shape, so the screens
// run unchanged in Offline Mode (docs/offline-mode-plan.md, section 2).
// JellyfinClient hands it a GET while Offline Mode is on and decodes the
// answer exactly as it would a server reply.
//
// The desktop's src/core/offline-query.ts is the same engine, line for line
// where it can be; test/fixtures/offline-query.json at the repo root holds
// cases both are tested against (OfflineQueryTests), so the two stay in step.
// Change one, change the other.
//
// It answers exactly the routes and params docs/offline-request-map.md found
// the screens sending. Anything else answers an empty list marked
// unknownRoute, never a network call. Only what is on disk is answered.
//
// Sorting compares lowercased text by Unicode scalar, not with localized
// comparison, so the desktop and Apple order things identically whatever the
// system language.

public struct OfflineAnswer: Sendable {
    /// 200, or 404 for an id the catalog does not hold.
    public var status: Int
    /// JSON, in Jellyfin's key case.
    public var body: Data
    /// The route is not one the engine knows: the body is an empty list.
    public var unknownRoute: Bool
}

public enum OfflineQuery {
    /// An engine over one state of the catalog. Keep it while the catalog
    /// is unchanged and make a new one when it changes: what it has built is
    /// not rebuilt. Measured on the desktop's twin with 20,000 songs: about
    /// 60 ms to build, then about 15 ms a request.
    public final class Engine {
        let catalog: Catalog

        public init(_ index: OfflineIndex) { catalog = Catalog(index) }

        /// Answers one GET. `path` is the route as the app sends it (a query
        /// string on it is read too); `params` the query, names in any case.
        /// `random` drives SortBy=Random.
        public func answer(path: String, params: [String: String?] = [:],
                           random: () -> Double = { Double.random(in: 0..<1) }) -> OfflineAnswer {
            OfflineQuery.route(catalog, path, params, random)
        }
    }

    /// Answers one GET from the catalog as it is now.
    public static func answer(_ index: OfflineIndex, path: String, params: [String: String?] = [:],
                              random: () -> Double = { Double.random(in: 0..<1) }) -> OfflineAnswer {
        Engine(index).answer(path: path, params: params, random: random)
    }

    static func route(_ c: Catalog, _ path: String, _ params: [String: String?], _ random: () -> Double) -> OfflineAnswer {
        let (seg, p) = readParams(path, params)
        let s = seg.map { $0.lowercased() }
        func id(_ i: Int) -> String { normId(seg[i]) }
        let idLike: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }

        switch s.count {
        case 1 where s[0] == "items": return items(c, p, random)
        case 2 where s[0] == "items" && s[1] == "latest": return latest(c, p)
        case 2 where s[0] == "items" && s[1] == "filters": return queryFilters(c, p)
        case 2 where s[0] == "items" && idLike(s[1]) && !reserved.contains(s[1]): return oneItem(c, id(1))
        case 1 where s[0] == "userviews": return views(c)
        case 2 where s[0] == "users" && idLike(s[1]): return user(c, s[1] == "me" ? "me" : id(1))
        case 3 where s[0] == "playlists" && s[2] == "items": return playlistItems(c, id(1), p)
        case 2 where s[0] == "playlists": return playlist(c, id(1))
        case 2 where s[0] == "shows" && s[1] == "nextup": return nextUp(c, p, random)
        case 3 where s[0] == "shows" && s[2] == "seasons": return seasons(c, id(1), p, random)
        case 3 where s[0] == "shows" && s[2] == "episodes": return episodes(c, id(1), p, random)
        case 2 where s[0] == "mediasegments": return segments(c, id(1))
        case 1 where s[0] == "artists": return derivedList(c.artists, p, random)
        case 2 where s[0] == "artists" && s[1] == "albumartists": return derivedList(c.albumArtists, p, random)
        case 1 where s[0] == "persons": return persons(c, p, random)
        case 1 where s[0] == "musicgenres": return derivedList(c.musicGenres, p, random)
        case 1 where s[0] == "genres": return derivedList(c.genres, p, random)
        default: return OfflineAnswer(status: 200, body: encode(Page(items: [], totalRecordCount: 0, startIndex: 0)), unknownRoute: true)
        }
    }

    /// The placeholder libraries' ids, which Offline Mode adds to the
    /// libraries a screen fans out over, so downloads whose library is not
    /// known yet still show (plan, section 1).
    public static var placeholderLibraryIds: [String] {
        OfflineIndex.placeholderOrder.compactMap { OfflineIndex.placeholderLibraries[$0]?.id }
    }

    /// /Items/<word> routes that are not an item id.
    static let reserved: Set<String> = ["latest", "filters", "filters2", "root", "counts", "resume"]

    // MARK: - Shapes

    struct Page: Encodable {
        var items: [JfItem]
        var totalRecordCount: Int
        var startIndex: Int
    }

    struct PlaylistDto: Encodable {
        var openAccess: Bool
        var shares: [String]
        var itemIds: [String]
    }

    struct QueryFilters: Encodable {
        var genres: [String]
        var tags: [String]
        var officialRatings: [String]
        var years: [Int]
    }

    struct SegmentDto: Encodable {
        var itemId: String
        var type: String
        var startTicks: Int
        var endTicks: Int
    }

    struct SegmentPage: Encodable {
        var items: [SegmentDto]
        var totalRecordCount: Int
        var startIndex: Int
    }

    static func encode<T: Encodable>(_ value: T) -> Data { (try? JSON.encoder.encode(value)) ?? Data("{}".utf8) }
    static func ok<T: Encodable>(_ value: T) -> OfflineAnswer { OfflineAnswer(status: 200, body: encode(value), unknownRoute: false) }
    static let notFound = OfflineAnswer(status: 404, body: Data("null".utf8), unknownRoute: false)

    /// Jellyfin ids compare without case or dashes ("N" and "D" GUID formats).
    static func normId(_ id: String) -> String {
        // Most ids already are (lowercase hex, no dashes): no copy then.
        guard id.utf8.contains(where: { $0 == 45 || (65...90).contains($0) || $0 >= 128 }) else { return id }
        return String(id.lowercased().filter { $0 != "-" })
    }

    // MARK: - Requests

    typealias Params = [String: String]

    static func readParams(_ path: String, _ params: [String: String?]) -> ([String], Params) {
        var out: Params = [:]
        var path = path
        if let q = path.firstIndex(of: "?") {
            for item in URLComponents(string: "x" + path[q...])?.queryItems ?? [] {
                out[item.name.lowercased()] = item.value ?? ""
            }
            path = String(path[..<q])
        }
        for (k, v) in params { if let v { out[k.lowercased()] = v } }
        return (path.split(separator: "/").map(String.init), out)
    }

    static func list(_ p: Params, _ key: String, separator: Character = ",") -> [String] {
        (p[key] ?? "").split(separator: separator, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func bool(_ p: Params, _ key: String) -> Bool? {
        switch (p[key] ?? "").lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func int(_ p: Params, _ key: String) -> Int? {
        guard let v = p[key], let n = Int(v.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }

    // MARK: - The catalog as entries

    /// A resolved catalog entry: the item as the screens see it, plus what
    /// the filters match on, every id normalized (normId). Arrays rather
    /// than sets: each holds one to three ids, and a large catalog spent its
    /// build allocating sets.
    struct Entry {
        var item: JfItem
        /// Library ids it belongs to (an artist or genre can span several).
        var libraries: [String]
        /// Ids a ParentId may name to reach it: album, series, season,
        /// playlists.
        var parents: [String] = []
        var artistIds: [String] = []
        var albumArtistIds: [String] = []
        var genreIds: [String] = []
        /// A genre's item types, lowercased, for /Genres?IncludeItemTypes=.
        var types: [String] = []
        let key: String

        init(item: JfItem, libraries: [String], parents: [String] = [], artistIds: [String] = [],
             albumArtistIds: [String] = [], genreIds: [String] = [], types: [String] = []) {
            self.item = item
            self.libraries = libraries
            self.parents = parents
            self.artistIds = artistIds
            self.albumArtistIds = albumArtistIds
            self.genreIds = genreIds
            self.types = types
            key = normId(item.id)
        }
    }

    /// Without repeats, first occurrence kept. The lists here are short.
    static func uniq(_ xs: [String]) -> [String] {
        guard xs.count > 1 else { return xs }
        var out: [String] = []
        for x in xs where !out.contains(x) { out.append(x) }
        return out
    }

    static func ids(_ list: [JfNameId]?) -> [String] { (list ?? []).map { normId($0.id) } }

    /// What the engine sees: every ready media item, and, built on first
    /// use, the albums, playlists, shows, artists and genres they imply.
    final class Catalog {
        let index: OfflineIndex
        private(set) var media: [Entry] = []
        private var mediaById: [String: Entry] = [:]

        init(_ index: OfflineIndex) {
            self.index = index
            var playlistsOf: [String: [String]] = [:]
            for c in index.collections where c.item.type == "Playlist" {
                for id in c.trackIds { playlistsOf[id, default: []].append(normId(c.item.id)) }
            }
            // Ids in a fixed order (normalized, then by scalar, as the
            // desktop's < on the same ASCII strings), since an album made from
            // its tracks takes the first track's fields.
            let ready = index.tracks.keys.filter { index.tracks[$0]?.file != nil }
                .map { (normId($0), $0) }.sorted { $0.0 < $1.0 }
            for (key, id) in ready {
                let item = index.tracks[id]!.item
                var parents = playlistsOf[id] ?? []
                for p in [item.albumId, item.seriesId, item.seasonId].compactMap({ $0 }) { parents.append(normId(p)) }
                let albumArtistIds = ids(item.albumArtists)
                let e = Entry(item: item, libraries: [normId(index.library(of: id)!)], parents: parents,
                              artistIds: uniq(ids(item.artistItems) + albumArtistIds),
                              albumArtistIds: albumArtistIds, genreIds: ids(item.genreItems))
                media.append(e)
                mediaById[key] = e
            }
        }

        lazy var albums: [Entry] = {
            var stored: [String: JfItem] = [:]
            for c in index.collections where c.item.type == "MusicAlbum" { stored[normId(c.item.id)] = c.item }
            var byAlbum: [String: [Entry]] = [:]
            for e in media where e.item.type == nil || e.item.type == "Audio" {
                guard let album = e.item.albumId else { continue }
                byAlbum[normId(album), default: []].append(e)
            }
            return byAlbum.keys.sorted { cmpText($0, $1) < 0 }.map { key in
                let tracks = byAlbum[key]!
                let first = tracks[0].item
                var item: JfItem
                if let s = stored[key] {
                    item = s
                } else {
                    item = JfItem(id: first.albumId!, name: first.album, type: "MusicAlbum")
                    item.albumArtist = first.albumArtist
                    item.albumArtists = first.albumArtists
                    item.productionYear = first.productionYear
                    if let tag = first.albumPrimaryImageTag { item.imageTags = JfImageTags(primary: tag) }
                    item.childCount = tracks.count
                }
                var genreOrder: [String] = []
                var genreById: [String: JfNameId] = [:]
                for t in tracks {
                    for g in t.item.genreItems ?? [] where genreById[normId(g.id)] == nil {
                        genreOrder.append(normId(g.id))
                        genreById[normId(g.id)] = g
                    }
                }
                if item.dateCreated == nil { item.dateCreated = dateCreated(of: tracks) }
                if item.genreItems == nil && !genreOrder.isEmpty {
                    item.genreItems = genreOrder.map { genreById[$0]! }
                    item.genres = genreOrder.map { genreById[$0]!.name ?? "" }
                }
                return Entry(item: item, libraries: uniqueSet(tracks.flatMap(\.libraries)),
                             artistIds: uniqueSet(ids(item.albumArtists) + ids(item.artistItems) + tracks.flatMap(\.artistIds)),
                             albumArtistIds: uniqueSet(ids(item.albumArtists) + tracks.flatMap(\.albumArtistIds)),
                             genreIds: uniq(ids(item.genreItems) + genreOrder))
            }
        }()

        private lazy var playlistParts: (list: [Entry], tracks: [String: [Entry]]) = {
            var list: [Entry] = []
            var tracksOf: [String: [Entry]] = [:]
            for c in index.collections.sorted(by: { cmpText($0.item.id, $1.item.id) < 0 }) where c.item.type == "Playlist" {
                let tracks = c.trackIds.compactMap { mediaById[normId($0)] }
                guard !tracks.isEmpty else { continue }
                var item = c.item
                item.childCount = tracks.count
                list.append(Entry(item: item, libraries: []))
                tracksOf[normId(c.item.id)] = tracks
            }
            return (list, tracksOf)
        }()

        var playlists: [Entry] { playlistParts.list }
        /// A playlist's ready tracks in playlist order.
        func playlistTracks(_ key: String) -> [Entry]? { playlistParts.tracks[key] }

        /// Series and seasons with a ready episode. A season the catalog has
        /// no container for is made from the episode's own fields.
        lazy var containers: [Entry] = {
            let episodes = media.filter { $0.item.type == "Episode" }
            var made: [String: JfItem] = [:]
            var under: [String: [Entry]] = [:]
            for e in episodes {
                let ep = e.item
                if let sid = ep.seriesId {
                    let key = normId(sid)
                    if made[key] == nil { made[key] = index.containers[sid] ?? JfItem(id: sid, name: ep.seriesName, type: "Series") }
                    under[key, default: []].append(e)
                }
                if let season = ep.seasonId {
                    let key = normId(season)
                    if made[key] == nil {
                        if let stored = index.containers[season] {
                            made[key] = stored
                        } else {
                            var s = JfItem(id: season, name: ep.seasonName, type: "Season")
                            s.seriesId = ep.seriesId
                            s.seriesName = ep.seriesName
                            s.indexNumber = ep.parentIndexNumber
                            made[key] = s
                        }
                    }
                    under[key, default: []].append(e)
                }
            }
            return made.keys.sorted { cmpText($0, $1) < 0 }.map { key in
                var item = made[key]!
                let eps = under[key] ?? []
                if item.type == "Series", item.dateCreated == nil { item.dateCreated = dateCreated(of: eps) }
                let parents = item.type == "Season" ? item.seriesId.map { [normId($0)] } ?? [] : []
                return Entry(item: item, libraries: uniqueSet(eps.flatMap(\.libraries)), parents: parents,
                             genreIds: ids(item.genreItems))
            }
        }()

        /// Artists, derived from what is downloaded.
        private func people(_ pick: (JfItem) -> [JfNameId]) -> [Entry] {
            var found: [String: (first: JfNameId, libs: Set<String>)] = [:]
            for e in media {
                for a in pick(e.item) {
                    let key = normId(a.id)
                    var f = found[key] ?? (a, [])
                    f.libs.formUnion(e.libraries)
                    found[key] = f
                }
            }
            return found.keys.sorted { cmpText($0, $1) < 0 }.map { key in
                let f = found[key]!
                return Entry(item: JfItem(id: f.first.id, name: f.first.name ?? "", type: "MusicArtist"), libraries: f.libs.sorted())
            }
        }

        lazy var artists: [Entry] = people { ($0.artistItems ?? []) + ($0.albumArtists ?? []) }
        lazy var albumArtists: [Entry] = people { $0.albumArtists ?? [] }

        private func genreList(_ from: [Entry], type: String) -> [Entry] {
            var found: [String: (item: JfNameId, libs: Set<String>, types: Set<String>)] = [:]
            for e in from {
                for g in e.item.genreItems ?? [] {
                    let key = normId(g.id)
                    var f = found[key] ?? (g, [], [])
                    f.libs.formUnion(e.libraries)
                    f.types.insert(typeOf(e))
                    found[key] = f
                }
            }
            return found.keys.sorted { cmpText($0, $1) < 0 }.map { key in
                let f = found[key]!
                return Entry(item: JfItem(id: f.item.id, name: f.item.name ?? "", type: type), libraries: f.libs.sorted(),
                             types: f.types.sorted())
            }
        }

        lazy var musicGenres: [Entry] = genreList(media.filter { typeOf($0) == "audio" } + albums, type: "MusicGenre")
        lazy var genres: [Entry] = genreList(media + albums + containers.filter { $0.item.type == "Series" }, type: "Genre")

        /// Everything /Items may list, or with `types` (lowercased) only the
        /// parts that can hold those types, so a songs query builds no
        /// albums. Artists and genres only when asked for by type or id, as
        /// Jellyfin keeps them outside the library folders.
        func all(withPeople: Bool, types: Set<String> = []) -> [Entry] {
            func want(_ kinds: String...) -> Bool { types.isEmpty || kinds.contains(where: types.contains) }
            var out: [Entry] = []
            if want("audio", "movie", "episode") { out += media }
            if want("musicalbum") { out += albums }
            if want("playlist") { out += playlists }
            if want("series", "season") { out += containers }
            if withPeople && want("musicartist") { out += artists }
            if withPeople && want("musicgenre") { out += musicGenres }
            return out
        }

        /// One entry by (normalized) id, in the order Jellyfin's kinds take
        /// precedence: a file, then what it implies.
        func byId(_ key: String) -> Entry? {
            if let e = mediaById[key] { return e }
            for list in [albums, playlists, containers, artists, albumArtists, musicGenres, genres] {
                if let e = list.first(where: { $0.key == key }) { return e }
            }
            return nil
        }

        func libraryView(_ id: String) -> JfItem? {
            guard let v = index.librariesInUse.first(where: { normId($0.id) == id }) else { return nil }
            var item = JfItem(id: v.id, name: v.name, type: "CollectionFolder")
            item.collectionType = v.collectionType
            return item
        }

        func isLibrary(_ id: String) -> Bool {
            index.libraries.contains { normId($0.id) == id } || OfflineQuery.placeholderLibraryIds.contains { normId($0) == id }
        }
    }

    /// The newest DateCreated among some entries, for an album or show the
    /// catalog did not store one for.
    static func dateCreated(of entries: [Entry]) -> String? {
        var best: (String, Double)?
        for e in entries {
            guard let d = e.item.dateCreated, let t = time(d) else { continue }
            if best == nil || t > best!.1 { best = (d, t) }
        }
        return best?.0
    }

    // MARK: - Sorting

    /// Lowercased text by Unicode scalar: the same order on every system.
    static func cmpText(_ a: String, _ b: String) -> Int {
        if a.utf8.elementsEqual(b.utf8) { return 0 }
        return cmpLowered(a.lowercased(), b.lowercased())
    }

    /// cmpText on text already lowercased. UTF-8 bytes compare in the same
    /// order as the code points they encode, which is the desktop's order,
    /// and bytes are the fast way to compare a Swift string.
    static func cmpLowered(_ x: String, _ y: String) -> Int {
        if x.utf8.elementsEqual(y.utf8) { return 0 }
        return x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : 1
    }

    /// Milliseconds since 1970, as Date.parse gives on the desktop for the
    /// ISO 8601 dates Jellyfin sends ("2026-10-01T08:00:00.0000000Z", up to
    /// seven fractional digits, which ISO8601DateFormatter does not read).
    /// Parsed by hand: sorting calls this for every item, and a formatter per
    /// call made sorting a large library slow. A time with no zone is UTC.
    static func time(_ s: String?) -> Double? {
        guard let s else { return nil }
        let c = Array(s.utf8)
        var i = 0
        func number(_ width: Int) -> Int? {
            guard i + width <= c.count else { return nil }
            var n = 0
            for k in i..<(i + width) {
                guard c[k] >= 48 && c[k] <= 57 else { return nil }
                n = n * 10 + Int(c[k] - 48)
            }
            i += width
            return n
        }
        func expect(_ ch: UInt8) -> Bool {
            guard i < c.count, c[i] == ch else { return false }
            i += 1
            return true
        }
        guard let y = number(4), expect(45), let mo = number(2), expect(45), let d = number(2),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var hour = 0, minute = 0, second = 0, millis = 0, offset = 0
        if i < c.count {
            guard expect(84) || expect(32), let h = number(2), expect(58), let mi = number(2) else { return nil }
            hour = h
            minute = mi
            if expect(58) { guard let sec = number(2) else { return nil }; second = sec }
            if expect(46) {
                var digits = 0
                while i < c.count, c[i] >= 48, c[i] <= 57 {
                    if digits < 3 { millis = millis * 10 + Int(c[i] - 48) }
                    digits += 1
                    i += 1
                }
                guard digits > 0 else { return nil }
                for _ in min(digits, 3)..<3 { millis *= 10 }
            }
            if expect(90) {
                // Z
            } else if i < c.count, c[i] == 43 || c[i] == 45 {
                let sign = c[i] == 45 ? -1 : 1
                i += 1
                guard let oh = number(2) else { return nil }
                _ = expect(58)
                guard let om = number(2) else { return nil }
                offset = sign * (oh * 60 + om)
            }
            guard i == c.count, hour < 24, minute < 60, second < 61 else { return nil }
        }
        // Days from 1970-01-01 in the proleptic Gregorian calendar.
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset * 60
        return Double(seconds) * 1000 + Double(millis)
    }

    enum SortValue {
        case text(String), number(Double), none
    }

    static let sortKeys: Set<String> = ["sortname", "name", "album", "albumartist", "datecreated", "dateplayed",
                                        "playcount", "productionyear", "parentindexnumber", "indexnumber",
                                        "communityrating", "runtime"]

    /// One SortBy key's value. None sorts first ascending, as Jellyfin's do.
    static func sortValue(_ i: JfItem, _ key: String) -> SortValue {
        func n(_ v: Int?) -> SortValue { v.map { .number(Double($0)) } ?? .none }
        switch key {
        case "sortname": return .text((i.sortName ?? i.name ?? "").lowercased())
        case "name": return .text((i.name ?? "").lowercased())
        case "album": return .text((i.album ?? "").lowercased())
        case "albumartist": return .text((i.albumArtist ?? i.artists?.first ?? "").lowercased())
        case "datecreated": return time(i.dateCreated).map { .number($0) } ?? .none
        case "dateplayed": return time(i.userData?.lastPlayedDate).map { .number($0) } ?? .none
        case "playcount": return .number(Double(i.userData?.playCount ?? 0))
        case "productionyear": return n(i.productionYear)
        case "parentindexnumber": return n(i.parentIndexNumber)
        case "indexnumber": return n(i.indexNumber)
        case "communityrating": return i.communityRating.map { .number($0) } ?? .none
        case "runtime": return n(i.runTimeTicks)
        default: return .none
        }
    }

    static func compare(_ a: SortValue, _ b: SortValue) -> Int {
        switch (a, b) {
        case (.none, .none): return 0
        case (.none, _): return -1
        case (_, .none): return 1
        case let (.text(x), .text(y)): return cmpLowered(x, y)
        case let (.number(x), .number(y)): return x < y ? -1 : (x > y ? 1 : 0)
        default: return 0
        }
    }

    /// Sorts by Jellyfin SortBy keys (unknown ones ignored) and SortOrder
    /// (one for all, or one per key), the id breaking any tie.
    static func sortEntries(_ entries: [Entry], _ p: Params, _ random: () -> Double, fallback: [String]) -> [Entry] {
        let keys = list(p, "sortby").map { $0.lowercased() }
        if keys.contains("random") {
            var out = entries
            if out.count > 1 {
                for i in stride(from: out.count - 1, to: 0, by: -1) {
                    let j = Int((random() * Double(i + 1)).rounded(.down))
                    out.swapAt(i, min(j, i))
                }
            }
            return out
        }
        let orders = list(p, "sortorder").map { $0.lowercased() == "descending" ? -1 : 1 }
        let chosen = (keys.isEmpty ? fallback : keys).filter { sortKeys.contains($0) }
        // Each key's value worked out once per entry, not once per comparison.
        // One flat array, entry by entry, each key's value worked out once.
        let n = chosen.count
        var values: [SortValue] = []
        values.reserveCapacity(entries.count * n)
        for e in entries { for key in chosen { values.append(sortValue(e.item, key)) } }
        let dirs = chosen.indices.map { $0 < orders.count ? orders[$0] : (orders.first ?? 1) }
        let tie = entries.map { $0.item.id.lowercased() }
        let order = entries.indices.sorted { x, y in
            for k in 0..<n {
                let c = compare(values[x * n + k], values[y * n + k])
                if c != 0 { return c * dirs[k] < 0 }
            }
            return cmpLowered(tie[x], tie[y]) < 0
        }
        return order.map { entries[$0] }
    }

    static func page(_ entries: [Entry], _ p: Params) -> Page {
        let start = int(p, "startindex") ?? 0
        let limit = int(p, "limit")
        let lower = min(start, entries.count)
        let upper = limit.map { min(entries.count, start + $0) } ?? entries.count
        return Page(items: lower < upper ? entries[lower..<upper].map(\.item) : [], totalRecordCount: entries.count, startIndex: start)
    }

    // MARK: - Filters

    /// Accents and case folded away, as the desktop's NFD-and-strip-marks.
    static func fold(_ s: String) -> String {
        let scalars = s.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return false
            default: return true
            }
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    /// The filters /Items and the artist and genre lists share.
    static func filterEntries(_ entries: [Entry], _ p: Params) -> [Entry] {
        func wanted(_ key: String) -> Set<String> { Set(list(p, key).map(normId)) }
        let artistIds = wanted("artistids"), albumArtistIds = wanted("albumartistids"), genreIds = wanted("genreids")
        let genreNames = Set(list(p, "genres", separator: "|").map(fold))
        let artistNames = Set(list(p, "artists", separator: "|").map(fold))
        let years = Set(list(p, "years").compactMap { Int($0) })
        let term = fold(p["searchterm"] ?? "").trimmingCharacters(in: .whitespaces)
        let filters = Set(list(p, "filters").map { $0.lowercased() })
        let favorite = bool(p, "isfavorite") ?? (filters.contains("isfavorite") ? true : nil)
        let played = bool(p, "isplayed") ?? (filters.contains("isplayed") ? true : filters.contains("isunplayed") ? false : nil)
        let resumable = filters.contains("isresumable")

        return entries.filter { e in
            let item = e.item
            if !artistIds.isEmpty && !e.artistIds.contains(where: artistIds.contains) { return false }
            if !albumArtistIds.isEmpty && !e.albumArtistIds.contains(where: albumArtistIds.contains) { return false }
            if !genreIds.isEmpty && !e.genreIds.contains(where: genreIds.contains) { return false }
            if !genreNames.isEmpty && !(item.genres ?? []).contains(where: { genreNames.contains(fold($0)) }) { return false }
            if !artistNames.isEmpty && !((item.artists ?? []) + [item.albumArtist ?? ""]).contains(where: { artistNames.contains(fold($0)) }) { return false }
            if !years.isEmpty && !years.contains(item.productionYear ?? Int.min) { return false }
            if !term.isEmpty && !fold(item.name ?? "").contains(term) { return false }
            if let favorite, (item.userData?.isFavorite == true) != favorite { return false }
            if let played, (item.userData?.played == true) != played { return false }
            if resumable && !((item.userData?.playbackPositionTicks ?? 0) > 0) { return false }
            return true
        }
    }

    /// Distinct, in a fixed order, so libraries and ids never depend on a
    /// set's iteration order.
    static func uniqueSet(_ xs: [String]) -> [String] { Array(Set(xs)).sorted() }

    static func inLibrary(_ entries: [Entry], _ parent: String?) -> [Entry] {
        guard let parent else { return entries }
        return entries.filter { $0.libraries.contains(parent) }
    }

    static func types(_ p: Params) -> Set<String> { Set(list(p, "includeitemtypes").map { $0.lowercased() }) }
    static func parent(_ p: Params) -> String? { p["parentid"].map(normId) }
    static func typeOf(_ e: Entry) -> String { (e.item.type ?? "Audio").lowercased() }

    // MARK: - Routes

    static func items(_ c: Catalog, _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        let types = types(p)
        let idList = list(p, "ids").map(normId)
        let parent = parent(p)
        let wantsPeople = !idList.isEmpty || types.contains("musicartist") || types.contains("musicgenre")
        var entries = c.all(withPeople: wantsPeople, types: types)
        var fallback = ["sortname"]

        if !idList.isEmpty {
            let set = Set(idList)
            entries = entries.filter { set.contains($0.key) }
        }
        if let parent {
            let playlist = c.playlistTracks(parent)
            if types == ["playlist"] && playlist == nil {
                // Jellyfin 12: playlists holding the parent's items.
                let under = Set(c.media.filter { $0.parents.contains(parent) || $0.libraries.contains(parent) }.map(\.key))
                entries = entries.filter { e in
                    e.item.type == "Playlist" && (c.playlistTracks(e.key) ?? []).contains { under.contains($0.key) }
                }
            } else if let playlist {
                let present = Set(entries.map(\.key))
                entries = playlist.filter { present.contains($0.key) }
                fallback = []
            } else if c.isLibrary(parent) {
                entries = inLibrary(entries.filter { $0.item.type != "Playlist" }, parent)
            } else {
                // An album, series or season: in disc and track (or season
                // and episode) order unless a sort is asked for.
                entries = entries.filter { $0.parents.contains(parent) }
                fallback = ["parentindexnumber", "indexnumber", "sortname"]
            }
        }
        if !types.isEmpty { entries = entries.filter { types.contains(typeOf($0)) } }
        entries = filterEntries(entries, p)
        // A playlist keeps its own order unless a sort is asked for.
        let sorted = !fallback.isEmpty || p["sortby"] != nil ? sortEntries(entries, p, random, fallback: fallback) : entries
        return ok(page(sorted, p))
    }

    static func oneItem(_ c: Catalog, _ id: String) -> OfflineAnswer {
        if let e = c.byId(id) { return ok(e.item) }
        return c.libraryView(id).map { ok($0) } ?? notFound
    }

    static func latest(_ c: Catalog, _ p: Params) -> OfflineAnswer {
        let types = types(p)
        var entries = inLibrary(c.media, parent(p))
        if !types.isEmpty { entries = entries.filter { types.contains(typeOf($0)) } }
        let sorted = sortEntries(entries, ["sortby": "DateCreated", "sortorder": "Descending"], { 0 }, fallback: [])
        return ok(Array(sorted.prefix(int(p, "limit") ?? 20)).map(\.item))
    }

    static func queryFilters(_ c: Catalog, _ p: Params) -> OfflineAnswer {
        let types = types(p)
        var entries = inLibrary(c.all(withPeople: false, types: types), parent(p))
        if !types.isEmpty { entries = entries.filter { types.contains(typeOf($0)) } }
        func sortedUniq(_ xs: [String]) -> [String] { Set(xs).sorted { cmpText($0, $1) < 0 } }
        return ok(QueryFilters(
            genres: sortedUniq(entries.flatMap { $0.item.genres ?? [] }),
            tags: [],
            officialRatings: sortedUniq(entries.compactMap(\.item.officialRating)),
            years: Set(entries.compactMap(\.item.productionYear)).sorted()))
    }

    static func views(_ c: Catalog) -> OfflineAnswer {
        let out = c.index.librariesInUse.compactMap { c.libraryView(normId($0.id)) }
        return ok(Page(items: out, totalRecordCount: out.count, startIndex: 0))
    }

    static func user(_ c: Catalog, _ id: String) -> OfflineAnswer {
        guard let u = c.index.user, id == "me" || normId(u.id) == id else { return notFound }
        return ok(u)
    }

    static func playlistItems(_ c: Catalog, _ id: String, _ p: Params) -> OfflineAnswer {
        guard let tracks = c.playlistTracks(id) else { return notFound }
        return ok(page(tracks.map { t in
            var t = t
            if t.item.playlistItemId == nil { t.item.playlistItemId = t.item.id }
            return t
        }, p))
    }

    static func playlist(_ c: Catalog, _ id: String) -> OfflineAnswer {
        guard let tracks = c.playlistTracks(id), let e = c.playlists.first(where: { $0.key == id }) else { return notFound }
        return ok(PlaylistDto(openAccess: e.item.isPublic == true, shares: [], itemIds: tracks.map(\.item.id)))
    }

    static func seasons(_ c: Catalog, _ seriesId: String, _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        guard c.containers.contains(where: { $0.key == seriesId }) else { return notFound }
        let found = c.containers.filter { $0.item.type == "Season" && $0.parents.contains(seriesId) }
        return ok(page(sortEntries(found, [:], random, fallback: ["indexnumber", "sortname"]), p))
    }

    static func episodes(_ c: Catalog, _ seriesId: String, _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        guard c.containers.contains(where: { $0.key == seriesId }) else { return notFound }
        let season = p["seasonid"].map(normId)
        let found = c.media.filter {
            $0.item.type == "Episode" && $0.parents.contains(seriesId) && (season == nil || $0.parents.contains(season!))
        }
        return ok(page(sortEntries(found, [:], random, fallback: ["parentindexnumber", "indexnumber", "sortname"]), p))
    }

    /// Per show, the first unplayed episode after the last played one; shows
    /// not started are left out, as the server's Next Up leaves them. Most
    /// recently watched show first.
    static func nextUp(_ c: Catalog, _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        let onlySeries = p["seriesid"].map(normId)
        let resumable = bool(p, "enableresumable") != false
        var found: [(entry: Entry, last: Double)] = []
        for series in inLibrary(c.containers.filter { $0.item.type == "Series" }, parent(p)) {
            if let onlySeries, series.key != onlySeries { continue }
            let eps = sortEntries(c.media.filter { $0.item.type == "Episode" && $0.parents.contains(series.key) }, [:], random,
                                  fallback: ["parentindexnumber", "indexnumber", "sortname"])
            guard let lastPlayed = eps.lastIndex(where: { $0.item.userData?.played == true }) else { continue }
            guard let next = eps[(lastPlayed + 1)...].first(where: {
                $0.item.userData?.played != true && (resumable || !(($0.item.userData?.playbackPositionTicks ?? 0) > 0))
            }) else { continue }
            let last = eps.map { time($0.item.userData?.lastPlayedDate) ?? 0 }.max() ?? 0
            found.append((next, last))
        }
        found.sort { $0.last != $1.last ? $0.last > $1.last : cmpText($0.entry.item.id, $1.entry.item.id) < 0 }
        return ok(page(found.map(\.entry), p))
    }

    static func segments(_ c: Catalog, _ id: String) -> OfflineAnswer {
        let key = c.index.tracks.keys.first { normId($0) == id }
        let segs = key.flatMap { c.index.tracks[$0]?.file != nil ? c.index.tracks[$0]?.segments : nil } ?? []
        let out = segs.map { SegmentDto(itemId: key!, type: $0.type, startTicks: $0.startTicks, endTicks: $0.endTicks) }
        return ok(SegmentPage(items: out, totalRecordCount: out.count, startIndex: 0))
    }

    /// /Artists, /Artists/AlbumArtists, /Persons, /MusicGenres and /Genres:
    /// a derived list with the filters those routes take.
    static func derivedList(_ from: [Entry], _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        var entries = filterEntries(inLibrary(from, parent(p)), p)
        let types = types(p)
        if !types.isEmpty { entries = entries.filter { $0.types.contains(where: types.contains) } }
        return ok(page(sortEntries(entries, p, random, fallback: ["sortname"]), p))
    }

    static func persons(_ c: Catalog, _ p: Params, _ random: () -> Double) -> OfflineAnswer {
        let kinds = Set(list(p, "persontypes").map { $0.lowercased() })
        if !kinds.isEmpty && !kinds.contains("artist") && !kinds.contains("albumartist") {
            return ok(Page(items: [], totalRecordCount: 0, startIndex: 0))
        }
        return derivedList(kinds == ["albumartist"] ? c.albumArtists : c.artists, p, random)
    }
}
