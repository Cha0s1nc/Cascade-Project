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
                sortOrder: String = "Ascending", favoritesOnly: Bool = false) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "limit": String(limit),
            "startIndex": String(startIndex),
        ]) { _, new in new })
    }

    /// Albums whose tracks were played most recently, newest first. Jellyfin
    /// keeps no play date on an album itself, so this reads the played tracks
    /// and then fetches their albums. Capped: past a few hundred albums
    /// "recently" has stopped meaning anything, and the ids go in the URL.
    func recentlyPlayedAlbums(favoritesOnly: Bool = false, maxAlbums: Int = 200) async throws -> [JfItem] {
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
        ]) { _, new in new })
        return albumsByRecentPlay(playedTracks: played, albums: albums)
    }

    /// Album artists rather than every credited artist, which is the list a
    /// music app means by "Artists". A separate endpoint, not an item type; it
    /// takes one parentId, so several libraries are queried per library too.
    func artists(limit: Int = 500, startIndex: Int = 0, sortOrder: String = "Ascending",
                 favoritesOnly: Bool = false) async throws -> [JfItem] {
        try await itemsAcrossLibraries([
            "userId": currentConfig.userId,
            // The server's default for this route, stated so the libraries
            // can be put back in the same order after merging.
            "sortBy": "SortName",
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "limit": String(limit),
            "startIndex": String(startIndex),
        ], path: "/Artists/AlbumArtists")
    }

    /// A nil `limit` means every song, in one response.
    func songs(limit: Int? = 500, startIndex: Int = 0, sortBy: String = "SortName",
               sortOrder: String = "Ascending", favoritesOnly: Bool = false) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": sortBy,
            "sortOrder": sortOrder,
            "isFavorite": favoritesOnly ? "true" : nil,
            "fields": trackFields,
            "limit": limit.map(String.init),
            "startIndex": String(startIndex),
        ]) { _, new in new })
    }

    /// A random selection of songs, for Shuffle All. One request, so the
    /// first track starts without waiting for the whole library; capped,
    /// because a queue past a thousand songs is days of music and a big
    /// response on a phone. Shuffled again after merging: each library comes
    /// back in its own random order, joined one library after the other.
    func randomSongs(limit: Int = 1000, favoritesOnly: Bool = false) async throws -> [JfItem] {
        Array(try await songs(limit: limit, sortBy: "Random", favoritesOnly: favoritesOnly)
            .shuffled().prefix(limit))
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

    // MARK: - Home

    func recentlyAdded(limit: Int = 20) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "sortBy": "DateCreated",
            "sortOrder": "Descending",
            "limit": String(limit),
        ]) { _, new in new })
    }

    func recentlyPlayed(limit: Int = 20) async throws -> [JfItem] {
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
