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
