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

    /// One query per selected library, merged and de-duplicated by id. With no
    /// library selected this is a single unscoped query.
    ///
    /// Jellyfin has no "these parents" parameter, so scoping to more than one
    /// library genuinely is more than one request.
    func itemsAcrossLibraries(_ params: [String: String?]) async throws -> [JfItem] {
        let libraries = currentConfig.libraryIds
        guard !libraries.isEmpty else {
            let response: JfItemsResponse = try await get("/Items", params: params)
            return response.items ?? []
        }

        var merged: [JfItem] = []
        var seen = Set<String>()
        for library in libraries {
            var scoped = params
            scoped["parentId"] = library
            // One failing library must not sink the whole screen, so this
            // yields nothing for that library rather than throwing.
            let response: JfItemsResponse? = try? await get("/Items", params: scoped)
            for item in response?.items ?? [] where seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return merged
    }

    private var baseParams: [String: String?] {
        ["userId": currentConfig.userId, "recursive": "true"]
    }

    func albums(limit: Int = 500, startIndex: Int = 0) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "MusicAlbum",
            "sortBy": "SortName",
            "limit": String(limit),
            "startIndex": String(startIndex),
        ]) { _, new in new })
    }

    /// Album artists rather than every credited artist, which is the list a
    /// music app means by "Artists". A separate endpoint, not an item type.
    func artists(limit: Int = 500) async throws -> [JfItem] {
        let libraries = currentConfig.libraryIds
        var params: [String: String?] = ["userId": currentConfig.userId, "limit": String(limit)]
        // This endpoint takes one parentId, so with several libraries selected
        // it is queried per library, same as itemsAcrossLibraries.
        guard !libraries.isEmpty else {
            let response: JfItemsResponse = try await get("/Artists/AlbumArtists", params: params)
            return response.items ?? []
        }

        var merged: [JfItem] = []
        var seen = Set<String>()
        for library in libraries {
            params["parentId"] = library
            let response: JfItemsResponse? = try? await get("/Artists/AlbumArtists", params: params)
            for item in response?.items ?? [] where seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return merged
    }

    func songs(limit: Int = 500, startIndex: Int = 0) async throws -> [JfItem] {
        try await itemsAcrossLibraries(baseParams.merging([
            "includeItemTypes": "Audio",
            "sortBy": "SortName",
            "fields": trackFields,
            "limit": String(limit),
            "startIndex": String(startIndex),
        ]) { _, new in new })
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
