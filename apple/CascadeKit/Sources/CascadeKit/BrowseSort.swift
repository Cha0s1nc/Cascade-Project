import Foundation

// What each browsing screen can be sorted by, and the server's name for it.
//
// Sorting is the server's job, not the view's. Songs and Albums arrive a page
// at a time, and sorting only the pages loaded so far shows the wrong first
// row until the last page lands. So each choice maps to a sortBy the server
// understands; sortedLikeServer only puts several libraries back together.
// Every key used here is one sortedLikeServer handles (see its tests).

public extension SortDirection {
    /// Jellyfin's sortOrder value.
    var serverValue: String { self == .descending ? "Descending" : "Ascending" }
}

public extension SongSortField {
    /// Ties broken by name, the same tie-break sortSongs and the desktop use.
    var serverSortBy: String {
        switch self {
        case .name:   return "SortName"
        case .artist: return "AlbumArtist,SortName"
        case .album:  return "Album,SortName"
        case .added:  return "DateCreated,SortName"
        case .played: return "DatePlayed,SortName"
        }
    }
}

public enum AlbumSortField: String, Sendable, CaseIterable {
    case name, artist, year, added, played

    /// Nil for `played`: Jellyfin keeps no play date on an album (checked on
    /// 10.11.11, DatePlayed leaves albums in arbitrary order and their
    /// LastPlayedDate empty), so that order comes from the tracks instead.
    /// See `albumsByRecentPlay`.
    public var serverSortBy: String? {
        switch self {
        case .name:   return "SortName"
        case .artist: return "AlbumArtist,SortName"
        case .year:   return "ProductionYear,SortName"
        case .added:  return "DateCreated,SortName"
        case .played: return nil
        }
    }
}

public enum PlaylistSortField: String, Sendable, CaseIterable {
    case name, added

    public var serverSortBy: String {
        switch self {
        case .name:  return "SortName"
        case .added: return "DateCreated,SortName"
        }
    }
}

/// Albums in the order their tracks were last played, most recent first.
/// `playedTracks` is newest first; an album appears once, where its most
/// recently played track put it. Albums with no played track are left out:
/// "recently played" with never-played albums mixed in is just noise.
public func albumsByRecentPlay(playedTracks: [JfItem], albums: [JfItem]) -> [JfItem] {
    let rank = Dictionary(uniqueKeysWithValues: recentlyPlayedAlbumIds(playedTracks).enumerated().map { ($1, $0) })
    return albums.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
}

/// Album ids in the order `albumsByRecentPlay` ranks them, for fetching just
/// those albums.
public func recentlyPlayedAlbumIds(_ playedTracks: [JfItem]) -> [String] {
    var seen = Set<String>()
    return playedTracks.compactMap(\.albumId).filter { seen.insert($0).inserted }
}

// Picking a date or a year almost always means newest first, so choosing one
// flips the direction to match; the person can still flip it back.

public extension SongSortField {
    var defaultDirection: SortDirection { self == .added || self == .played ? .descending : .ascending }
}

public extension AlbumSortField {
    var defaultDirection: SortDirection { [.year, .added, .played].contains(self) ? .descending : .ascending }
}

public extension PlaylistSortField {
    var defaultDirection: SortDirection { self == .added ? .descending : .ascending }
}

/// What a browsing screen is narrowed to: the desktop's library filters
/// (src/core/library-browse.ts), favorites, genre, decade and played. The
/// desktop filters the loaded list; here the screens page in 200 at a time,
/// so filtering what has loaded would miss the rest, and the server filters.
public struct BrowseFilter: Hashable, Sendable {
    public enum Played: String, CaseIterable, Sendable { case any, played, unplayed }

    public var favoritesOnly = false
    /// A genre's name, as the desktop stores it in its prefs. The items
    /// routes filter by name (`genres`), and a name is the same in every
    /// library where an id is not.
    public var genre: String?
    /// The decade's first year: 1990 means 1990 to 1999.
    public var decade: Int?
    public var played: Played = .any

    public init(favoritesOnly: Bool = false, genre: String? = nil, decade: Int? = nil, played: Played = .any) {
        self.favoritesOnly = favoritesOnly
        self.genre = genre
        self.decade = decade
        self.played = played
    }

    public var isActive: Bool { self != BrowseFilter() }

    /// The query parameters, only the ones set: "false" would mean "only
    /// non-favorites" to the server, not "either".
    public var params: [String: String] {
        var out: [String: String] = [:]
        if favoritesOnly { out["isFavorite"] = "true" }
        if let genre { out["genres"] = genre }
        if let decade { out["years"] = (decade..<decade + 10).map(String.init).joined(separator: ",") }
        switch played {
        case .any: break
        case .played: out["isPlayed"] = "true"
        case .unplayed: out["isPlayed"] = "false"
        }
        return out
    }

    /// The decades those years fall in, newest first.
    public static func decades(_ years: [Int]) -> [Int] {
        Set(years.filter { $0 > 0 }.map { $0 / 10 * 10 }).sorted(by: >)
    }
}

/// Stored as "favorites|genre|decade|played", so a screen keeps its filter
/// between launches with @AppStorage. Anything that does not read back
/// cleanly falls back to no filter rather than reaching the server.
extension BrowseFilter: RawRepresentable {
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let played = Played(rawValue: parts[3]) else { return nil }
        self.init(favoritesOnly: parts[0] == "1", genre: parts[1].isEmpty ? nil : parts[1],
                  decade: Int(parts[2]), played: played)
    }

    public var rawValue: String {
        [favoritesOnly ? "1" : "0", genre ?? "", decade.map(String.init) ?? "", played.rawValue]
            .joined(separator: "|")
    }
}
