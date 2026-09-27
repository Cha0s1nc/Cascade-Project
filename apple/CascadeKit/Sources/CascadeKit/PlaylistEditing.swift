import Foundation

// Creating, renaming, deleting and editing playlists. Every route and body
// here was read from the server's own spec and then tried against Jellyfin
// 10.11.11 before being written down. Every call throws on a bad status
// (JellyfinClient.send), so a refused write never looks like a saved one.

public extension JfItem {
    /// What identifies this row within a playlist, for remove and move.
    var entryId: String { playlistItemId ?? id }
}

/// Where a row lands, as the server's Move route counts it (the final index),
/// given SwiftUI's onMove offset, which counts positions in the list BEFORE
/// the row is taken out. Dragging row 0 to just below row 2 arrives as offset
/// 3 and means index 2.
public func playlistMoveIndex(from source: Int, toOffset offset: Int) -> Int {
    offset > source ? offset - 1 : offset
}

/// POST /Playlists takes this as its body.
struct NewPlaylist: Encodable {
    var name: String
    var ids: [String]
    var userId: String
    var mediaType = "Audio"
}

/// POST /Playlists/{id}. Nil fields are left out of the JSON, and the server
/// leaves out-of-body fields alone: sending Ids would replace the contents.
struct PlaylistUpdate: Encodable {
    var name: String?
}

private struct CreatedPlaylist: Decodable {
    var id: String
}

public extension JellyfinClient {

    /// Creates an audio playlist owned by this user, optionally with tracks
    /// already in it. Returns the new playlist's id.
    func createPlaylist(name: String, itemIds: [String] = []) async throws -> String {
        let body = NewPlaylist(name: name, ids: itemIds, userId: currentConfig.userId)
        let created: CreatedPlaylist = try await post("/Playlists", body: body)
        return created.id
    }

    func renamePlaylist(_ playlistId: String, to name: String) async throws {
        try await postRaw("/Playlists/\(playlistId)", body: PlaylistUpdate(name: name))
    }

    /// There is no playlist-specific delete: a playlist is an item.
    func deletePlaylist(_ playlistId: String) async throws {
        try await delete("/Items/\(playlistId)")
    }

    /// Appends tracks. Jellyfin 10.11 silently skips one already there.
    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        try await postRaw("/Playlists/\(playlistId)/Items", body: Optional<EmptyBody>.none, params: [
            "ids": itemIds.joined(separator: ","),
            "userId": currentConfig.userId,
        ])
    }

    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        try await delete("/Playlists/\(playlistId)/Items", params: ["entryIds": entryIds.joined(separator: ",")])
    }

    /// Moves one entry to `index`, counted in the final order.
    func movePlaylistEntry(_ playlistId: String, entryId: String, to index: Int) async throws {
        try await postRaw("/Playlists/\(playlistId)/Items/\(entryId)/Move/\(index)", body: Optional<EmptyBody>.none)
    }
}
