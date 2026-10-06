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
/// leaves out-of-body fields alone: sending Ids would replace the contents,
/// which is exactly what the bulk save below wants and a rename must not.
struct PlaylistUpdate: Encodable {
    var name: String?
    var ids: [String]?
    var isPublic: Bool?
}

/// Bulk playlist editing over a selection of rows (src/core/playlist-edit.ts):
/// remove, and move to the top or bottom. Rows are selected by entry id (a
/// track can in principle appear twice), and the result is the new order for
/// `setPlaylistItems` to send.
public enum PlaylistEdit {
    /// Drop every selected row, keeping the rest in their existing order.
    public static func removing(_ items: [JfItem], selected: Set<String>) -> [JfItem] {
        items.filter { !selected.contains($0.entryId) }
    }

    /// Pull every selected row to the front, in their existing relative order.
    public static func movingToTop(_ items: [JfItem], selected: Set<String>) -> [JfItem] {
        let (chosen, rest) = split(items, selected)
        return chosen + rest
    }

    /// Push every selected row to the back, in their existing relative order.
    public static func movingToBottom(_ items: [JfItem], selected: Set<String>) -> [JfItem] {
        let (chosen, rest) = split(items, selected)
        return rest + chosen
    }

    private static func split(_ items: [JfItem], _ selected: Set<String>) -> ([JfItem], [JfItem]) {
        (items.filter { selected.contains($0.entryId) }, items.filter { !selected.contains($0.entryId) })
    }
}

/// The Playlists screen's sort fields, as the desktop stores them in
/// `cascade.playlistsPrefs` (name, added, count). Playlists are few and come
/// back whole, so sorting and filtering happen here, on the loaded list.
public enum PlaylistPrefsField: String, Sendable, CaseIterable {
    case name, added, count

    public var defaultDirection: SortDirection { self == .name ? .ascending : .descending }
}

public func arrangedPlaylists(_ items: [JfItem], by prefs: LibraryPrefs) -> [JfItem] {
    let field: PlaylistPrefsField = prefs.sortField(default: .name)
    let kept = prefs.filter.favoritesOnly ? items.filter { $0.userData?.isFavorite == true } : items
    let sorted = kept.enumerated().sorted { a, b in
        let order: ComparisonResult
        switch field {
        case .name: order = (a.element.sortName ?? a.element.name ?? "").localizedStandardCompare(b.element.sortName ?? b.element.name ?? "")
        case .added:
            let (x, y) = (a.element.dateCreated ?? "", b.element.dateCreated ?? "")
            order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case .count:
            let (x, y) = (a.element.childCount ?? 0, b.element.childCount ?? 0)
            order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        }
        if order == .orderedSame { return a.offset < b.offset }
        return prefs.direction == .descending ? order == .orderedDescending : order == .orderedAscending
    }
    return sorted.map(\.element)
}

/// What a playlist's own page needs beyond its tracks: whether it is public
/// (GET /Playlists/{id}'s OpenAccess; the item has no such field, which is
/// why the desktop's read of IsPublic always saw false) and whether this
/// account may change it (the item's CanDelete, the server's own check).
public struct PlaylistInfo: Sendable, Equatable {
    public var isPublic: Bool
    public var canEdit: Bool
}

private struct PlaylistDto: Decodable { var openAccess: Bool? }
private struct CanDeleteDto: Decodable { var canDelete: Bool? }

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

    /// Replaces the playlist's contents with `itemIds`, in that order, in one
    /// request: a remove or a move over many rows is one atomic write instead
    /// of a Move or DELETE per row. These are track ids, not entry ids.
    func setPlaylistItems(_ playlistId: String, itemIds: [String]) async throws {
        try await postRaw("/Playlists/\(playlistId)", body: PlaylistUpdate(ids: itemIds))
    }

    /// Name and public flag together, as the desktop's Rename / Public dialog
    /// sends them; contents untouched.
    func updatePlaylist(_ playlistId: String, name: String, isPublic: Bool) async throws {
        try await postRaw("/Playlists/\(playlistId)", body: PlaylistUpdate(name: name, isPublic: isPublic))
    }

    func playlistInfo(_ playlistId: String) async throws -> PlaylistInfo {
        let playlist: PlaylistDto = try await get("/Playlists/\(playlistId)")
        // An explicit false is trusted; anything else (true, or missing on an
        // older server) offers editing, and a refused write then says so.
        let item: CanDeleteDto = try await get("/Items/\(playlistId)", params: ["userId": currentConfig.userId])
        return PlaylistInfo(isPublic: playlist.openAccess == true, canEdit: item.canDelete != false)
    }
}
