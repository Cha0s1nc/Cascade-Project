import Foundation

// The queries every browsing screen shares.
//
// These live here rather than in the views so the parameter shapes are written
// once and verified once. Each was checked against the live server (Jellyfin
// 10.11.11) rather than recalled: writing against a remembered route is a
// mistake this project has already made on the desktop.

/// Fields worth asking for on a list of tracks. Jellyfin omits most of these
/// unless asked, and a missing DateCreated silently breaks "recently added"
/// sorting rather than erroring.
private let trackFields = "DateCreated,PrimaryImageAspectRatio"

public extension JellyfinClient {

    /// The user's libraries. Music ones have `collectionType == "music"`.
    func views() async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/UserViews",
                                                      params: ["userId": currentConfig.userId])
        return response.items ?? []
    }

    /// The music libraries this app should browse: whatever the user picked, or
    /// every music library if they have not picked yet.
    func musicLibraries() async throws -> [JfItem] {
        let music = try await views().filter { $0.collectionType == "music" }
        let chosen = currentConfig.libraryIds
        guard !chosen.isEmpty else { return music }
        return music.filter { chosen.contains($0.id) }
    }

    /// One query per selected library, run in parallel, merged in library
    /// order, with the same song, album or artist found in two libraries shown
    /// once (see mergeLibraryCopies). With no library selected this is a
    /// single unscoped query.
    ///
    /// Jellyfin has no "these parents" parameter, so scoping to more than one
    /// library genuinely is more than one request; they used to run one after
    /// another, which is most of why a multi-library screen felt slow.
    func itemsAcrossLibraries(_ params: [String: String?], path: String = "/Items") async throws -> [JfItem] {
        var libraries = currentConfig.libraryIds
        // Nothing picked means the whole server, and one unscoped query covers
        // that, but it cannot say which library an item came from, so an album
        // in two music libraries showed twice. With two or more, ask each one.
        // ponytail: one /UserViews request per call; cache it if Home's three
        // queries ever show up as slow.
        if libraries.isEmpty, let music = try? await views().filter({ $0.collectionType == "music" }), music.count > 1 {
            libraries = music.map(\.id)
        }
        var params = params
        var fields = [(params["fields"] ?? nil)].compactMap { $0 }
        // What sortedLikeServer needs to put several libraries back in one
        // order, and what the paged screens re-sort by. Cheap, so always.
        let sortBy = (params["sortBy"] ?? nil) ?? ""
        if sortBy.hasPrefix("SortName") { fields.append("SortName") }
        if sortBy.hasPrefix("DateCreated") { fields.append("DateCreated") }
        // What mergeLibraryCopies compares copies by: a song's bitrate, an
        // album's track count. Only worth the bigger response when there is
        // more than one library to choose between.
        if libraries.count > 1 {
            let types = (params["includeItemTypes"] ?? nil) ?? ""
            if types.contains("Audio") { fields.append("MediaSources") }
            if types.contains("MusicAlbum") { fields.append("ChildCount") }
        }
        if !fields.isEmpty { params["fields"] = fields.joined(separator: ",") }

        guard !libraries.isEmpty else {
            let response: JfItemsResponse = try await get(path, params: params)
            return response.items ?? []
        }

        let pages = await withTaskGroup(of: (Int, [JfItem]).self) { group in
            for (index, library) in libraries.enumerated() {
                var scoped = params
                scoped["parentId"] = library
                group.addTask {
                    // One failing library must not sink the whole screen, so
                    // it yields nothing rather than throwing.
                    let response: JfItemsResponse? = try? await self.get(path, params: scoped)
                    return (index, (response?.items ?? []).map { item in
                        var item = item
                        item.sourceLibrary = index
                        return item
                    })
                }
            }
            var byLibrary: [(Int, [JfItem])] = []
            for await page in group { byLibrary.append(page) }
            return byLibrary.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        let merged = mergeLibraryCopies(pages)
        return libraries.count > 1
            ? sortedLikeServer(merged, sortBy: params["sortBy"] ?? nil, sortOrder: params["sortOrder"] ?? nil)
            : merged
    }

    private var baseParams: [String: String?] {
        ["userId": currentConfig.userId, "recursive": "true"]
    }

    /// `favoritesOnly` is sent as nil rather than "false" when off: false
    /// would mean "only non-favorites" to the server.
    func albums(limit: Int = 500, startIndex: Int = 0, sortBy: String = "SortName",
                sortOrder: String = "Ascending", favoritesOnly: Bool = false,
                genreId: String? = nil, filter: BrowseFilter = .init()) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "genreIds": genreId,
            "limit": String(limit),
            "startIndex": String(startIndex),
        ]) { _, new in new }.applying(filter))
    }

    /// Albums whose tracks were played most recently, newest first. Jellyfin
    /// keeps no play date on an album itself, so this reads the played tracks
    /// and then fetches their albums. Capped: past a few hundred albums
    /// "recently" has stopped meaning anything, and the ids go in the URL.
    func recentlyPlayedAlbums(favoritesOnly: Bool = false, maxAlbums: Int = 200,
                              filter: BrowseFilter = .init()) async throws -> [JfItem] {
        let played = try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": "DatePlayed",
            "sortOrder": "Descending",
            "filters": "IsPlayed",
            "limit": "1000",
        ]) { _, new in new })
        let ids = Array(recentlyPlayedAlbumIds(played).prefix(maxAlbums))
        guard !ids.isEmpty else { return [] }
        let albums = try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "ids": ids.joined(separator: ","),
            "isFavorite": favoritesOnly ? "true" : nil,
        ]) { _, new in new }.applying(filter))
        return albumsByRecentPlay(playedTracks: played, albums: albums)
    }

    /// Album artists rather than every credited artist, which is the list a
    /// music app means by "Artists". A separate endpoint, not an item type; it
    /// takes one parentId, so several libraries are queried per library too.
    func artists(limit: Int = 500, startIndex: Int = 0, sortBy: String = "SortName", sortOrder: String = "Ascending",
                 favoritesOnly: Bool = false, filter: BrowseFilter = .init()) async throws -> [JfItem] {
        try await itemsAcrossLibraries([
            "userId": currentConfig.userId,
            // SortName is the server's default for this route, stated so the
            // libraries can be put back in the same order after merging.
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "limit": String(limit),
            "startIndex": String(startIndex),
        ].applying(filter), path: "/Artists/AlbumArtists")
    }

    /// A nil `limit` means every song, in one response.
    func songs(limit: Int? = 500, startIndex: Int = 0, sortBy: String = "SortName",
               sortOrder: String = "Ascending", favoritesOnly: Bool = false,
               genreId: String? = nil, filter: BrowseFilter = .init()) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "genreIds": genreId,
            "fields": trackFields,
            "limit": limit.map(String.init),
            "startIndex": String(startIndex),
        ]) { _, new in new }.applying(filter))
    }

    /// A random selection of songs, for Shuffle All. One request, so the
    /// first track starts without waiting for the whole library; capped,
    /// because a queue past a thousand songs is days of music and a big
    /// response on a phone. Shuffled again after merging: each library comes
    /// back in its own random order, joined one library after the other.
    func randomSongs(limit: Int = 1000, favoritesOnly: Bool = false,
                     genreId: String? = nil, filter: BrowseFilter = .init()) async throws -> [JfItem] {
        Array(try await songs(limit: limit, sortBy: "Random", favoritesOnly: favoritesOnly, genreId: genreId,
                              filter: filter)
            .shuffled().prefix(limit))
    }

    /// The music genres in the chosen libraries. Jellyfin gives a genre one
    /// id across libraries, so the merge's id check is what dedupes them.
    func genres() async throws -> [JfItem] {
        try await itemsAcrossLibraries([
            "userId": currentConfig.userId,
            "sortBy": "SortName",
        ], path: "/MusicGenres")
    }

    /// The years that have items of this type in the chosen libraries, for
    /// the decade filter: only decades that exist are offered, as on the
    /// desktop. /Items/Filters takes one parentId, so it is asked per library.
    func years(of itemType: String) async throws -> [Int] {
        struct Filters: Decodable { var years: [Int]? }
        let libraries = currentConfig.libraryIds
        var years = Set<Int>()
        for parent in libraries.isEmpty ? [nil] : libraries.map(Optional.some) {
            let found: Filters = try await get("/Items/Filters", params: [
                "userId": currentConfig.userId, "parentId": parent,
                "includeItemTypes": itemType, "recursive": "true",
            ])
            years.formUnion(found.years ?? [])
        }
        return years.sorted()
    }

    /// A genre's songs in album order, for its Play button.
    func songs(inGenre genreId: String) async throws -> [JfItem] {
        try await songs(limit: nil, sortBy: "AlbumArtist,Album,ParentIndexNumber,IndexNumber", genreId: genreId)
    }

    /// An album's tracks in playing order. Disc number first, because a
    /// two-disc album sorted on track number alone interleaves the discs.
    func tracks(inAlbum albumId: String) async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/Items", params: [
            "userId": currentConfig.userId,
            "parentId": albumId,
            "sortBy": "ParentIndexNumber,IndexNumber,SortName",
            "fields": trackFields,
        ])
        return response.items ?? []
    }

    /// The user's playlists. Not scoped to the chosen music libraries:
    /// playlists live in Jellyfin's own playlists collection, so the library
    /// filter would hide every one of them.
    func playlists(sortBy: String = "SortName", sortOrder: String = "Ascending") async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/Items", params: [
            "userId": currentConfig.userId,
            "includeItemTypes": "Playlist",
            "recursive": "true",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "fields": "ChildCount",
        ])
        return response.items ?? []
    }

    /// A playlist's tracks in the playlist's own order (no sortBy: the order
    /// is the playlist). Same route and fields the desktop uses.
    func tracks(inPlaylist playlistId: String) async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/Playlists/\(playlistId)/Items", params: [
            "userId": currentConfig.userId,
            "fields": trackFields,
        ])
        return response.items ?? []
    }

    /// An artist's albums, newest first.
    func albums(byArtist artistId: String) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "albumArtistIds": artistId,
            "includeItemTypes": "MusicAlbum",
            "sortBy": "ProductionYear,SortName",
            "sortOrder": "Descending",
        ]) { _, new in new })
    }

    /// Every track by an artist, for the artist page's play button.
    /// Artists Jellyfin rates similar, kept to the ones in the selected
    /// libraries: /Artists/{id}/Similar has no library scope of its own (its
    /// userId only applies permissions), so it is intersected with the album
    /// artists the Artists tab lists, which also means every one has albums
    /// to show. The desktop's fetchSimilarArtists, which intersects with all
    /// artists instead.
    func similarArtists(to artistId: String, limit: Int = 12) async throws -> [JfItem] {
        async let similar: JfItemsResponse = get("/Artists/\(artistId)/Similar",
                                                  params: ["userId": currentConfig.userId, "limit": "24"])
        async let inLibraries = itemsAcrossLibraries([
            "userId": currentConfig.userId, "enableImages": "false", "enableUserData": "false",
        ], path: "/Artists/AlbumArtists")
        let ids = Set(try await inLibraries.map(\.id))
        return Array((try await similar).items?.filter { ids.contains($0.id) }.prefix(limit) ?? [])
    }

    func tracks(byArtist artistId: String, limit: Int = 500) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "artistIds": artistId,
            "includeItemTypes": "Audio",
            "sortBy": "Album,ParentIndexNumber,IndexNumber",
            "fields": trackFields,
            "limit": String(limit),
        ]) { _, new in new })
    }

    /// Search across tracks, albums and artists at once. Jellyfin matches on a
    /// substring, so short terms return a lot; the caller sets the limit.
    func search(_ term: String, limit: Int = 60) async throws -> [JfItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await itemsAcrossLibraries(baseParams.merging([
            "searchTerm": trimmed,
            "includeItemTypes": "Audio,MusicAlbum,MusicArtist",
            "fields": trackFields,
            "limit": String(limit),
        ]) { _, new in new })
    }

    /// The desktop's search dropdown: songs, albums and artists, each its own
    /// query with its own cap (10, 8, 8), so one kind with many matches
    /// cannot crowd the others out of a single shared limit. Movies and shows
    /// (8 each) only when their library ids are given, which a music-only
    /// account never has. A kind that fails comes back empty rather than
    /// sinking the rest, as the desktop's allSettled does.
    func searchEverything(_ term: String, movieLibraries: [String] = [],
                          showLibraries: [String] = []) async throws -> SearchResults {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }
        async let songs = try? itemsAcrossLibraries(baseParams.merging([
            "searchTerm": trimmed, "includeItemTypes": "Audio", "fields": trackFields, "limit": "10",
        ]) { _, new in new })
        async let albums = try? itemsAcrossLibraries(baseParams.merging([
            "searchTerm": trimmed, "includeItemTypes": "MusicAlbum", "limit": "8",
        ]) { _, new in new })
        // /Artists, not /Items, as the desktop does: it is the route that
        // knows artists, and it finds track artists as well as album artists.
        async let artists = try? itemsAcrossLibraries([
            "userId": currentConfig.userId, "searchTerm": trimmed, "limit": "8",
        ], path: "/Artists")
        async let movies = movieLibraries.isEmpty
            ? nil : try? searchVideo(trimmed, type: "Movie", libraryIds: movieLibraries)
        async let shows = showLibraries.isEmpty
            ? nil : try? searchVideo(trimmed, type: "Series", libraryIds: showLibraries)
        // Each merged list is cut back to its cap: several libraries return a
        // full limit each.
        return SearchResults(songs: Array((await songs ?? []).prefix(10)),
                             albums: Array((await albums ?? []).prefix(8)),
                             artists: Array((await artists ?? []).prefix(8)),
                             movies: await movies ?? [], shows: await shows ?? [])
    }

    // MARK: - Home

    func recentlyAdded(limit: Int = 24) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "sortBy": "DateCreated",
            "sortOrder": "Descending",
            "limit": String(limit),
        ]) { _, new in new })
    }

    func recentlyPlayed(limit: Int = 24) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": "DatePlayed",
            "sortOrder": "Descending",
            // Without this the list is padded with never-played tracks, whose
            // DatePlayed is empty and which therefore sort arbitrarily.
            "filters": "IsPlayed",
            "fields": trackFields,
            "limit": String(limit),
        ]) { _, new in new })
    }

    func frequentlyPlayed(limit: Int = 20) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": "PlayCount",
            "sortOrder": "Descending",
            "filters": "IsPlayed",
            "fields": trackFields,
            "limit": String(limit),
        ]) { _, new in new })
    }

    // MARK: - Writes

    /// Mark an item played, or not.
    ///
    /// Note the route: userId is a QUERY parameter, and the older
    /// /Users/{userId}/PlayedItems/{id} route does not exist in 10.11.
    func setPlayed(_ played: Bool, itemId: String) async throws {
        let path = "/UserPlayedItems/\(itemId)"
        let params: [String: String?] = ["userId": currentConfig.userId]
        // Both throw on a bad status. A refused write that looked like a
        // successful one is the exact desktop bug this guards against.
        if played {
            try await postRaw(path, body: Optional<EmptyBody>.none, params: params)
        } else {
            try await delete(path, params: params)
        }
    }

    func setFavorite(_ favorite: Bool, itemId: String) async throws {
        let path = "/UserFavoriteItems/\(itemId)"
        let params: [String: String?] = ["userId": currentConfig.userId]
        if favorite {
            try await postRaw(path, body: Optional<EmptyBody>.none, params: params)
        } else {
            try await delete(path, params: params)
        }
    }
}

/// What the search box found, by kind.
public struct SearchResults: Sendable {
    public var songs: [JfItem] = []
    public var albums: [JfItem] = []
    public var artists: [JfItem] = []
    public var movies: [JfItem] = []
    public var shows: [JfItem] = []

    public init(songs: [JfItem] = [], albums: [JfItem] = [], artists: [JfItem] = [],
                movies: [JfItem] = [], shows: [JfItem] = []) {
        self.songs = songs; self.albums = albums; self.artists = artists
        self.movies = movies; self.shows = shows
    }

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty && artists.isEmpty && movies.isEmpty && shows.isEmpty }
}

public enum ArtistPage {
    /// How many songs the Top Songs shelf shows.
    public static let topSongsMax = 10

    /// The artist's songs this user has played most, ties by name so the
    /// order is stable. Jellyfin's only popularity figure is this user's own
    /// play count, so a song never played is not a top song: without the
    /// filter, an artist nobody has played got the whole track list again,
    /// alphabetized. The desktop's topSongsOf (src/core/artist-page.ts).
    public static func topSongs(_ songs: [JfItem], max: Int = topSongsMax) -> [JfItem] {
        songs.filter { ($0.userData?.playCount ?? 0) > 0 }
            .sorted {
                let (a, b) = ($0.userData?.playCount ?? 0, $1.userData?.playCount ?? 0)
                return a != b ? a > b : ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
            }
            .prefix(max)
            .map { $0 }
    }
}

extension Dictionary where Key == String, Value == String? {
    /// These parameters with a filter's on top, where it sets them.
    func applying(_ filter: BrowseFilter) -> [String: String?] {
        merging(filter.params.mapValues { Optional($0) }) { _, new in new }
    }
}
