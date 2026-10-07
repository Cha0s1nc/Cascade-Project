import Foundation

/// A playlist's picture and description, the desktop's playlist details
/// (src/core/playlist-edit.ts). Jellyfin lets only admins set them; the
/// Cascade Server plugin (capability `playlist-edit`) lets the playlist's
/// owner too, so it is preferred whenever it is there, even for an admin, so
/// both kinds of account take one path.
public enum PlaylistDetails {
    /// The plugin route's cap, and the desktop's.
    public static let maxImageBytes = 10 * 1024 * 1024
    public static let overviewMax = 2000

    public enum Route: Sendable, Equatable { case plugin, admin }

    /// Nil: neither path is open to this account, so the controls are not offered.
    public static func route(capabilities: Set<String>, pluginPresent: Bool, isAdmin: Bool) -> Route? {
        if pluginPresent, capabilities.contains("playlist-edit") { return .plugin }
        return isAdmin ? .admin : nil
    }

    /// What an image really is, from its first bytes, or nil for anything else.
    /// A file's extension can lie, and the server would get the wrong Content-Type.
    public static func imageType(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        func at(_ i: Int, _ v: [UInt8]) -> Bool { b.count >= i + v.count && Array(b[i..<i + v.count]) == v }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if at(0, [0x52, 0x49, 0x46, 0x46]), at(8, [0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
        return nil
    }

    public enum ImageError: Error, CustomStringConvertible {
        case notAnImage, tooLarge
        public var description: String {
            switch self {
            case .notAnImage: "That is not a JPEG, PNG or WebP image."
            case .tooLarge: "That picture is over 10 MB."
            }
        }
    }
}

public extension JellyfinClient {
    /// The description as the server has it (a full item, since a list's
    /// items leave Overview out unless asked).
    func playlistOverview(_ id: String) async throws -> String {
        (try await fullItem(itemId: id).object()["Overview"] as? String) ?? ""
    }

    /// Empty clears it.
    func setPlaylistOverview(_ id: String, _ overview: String, route: PlaylistDetails.Route) async throws {
        let text = String(overview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PlaylistDetails.overviewMax))
        switch route {
        case .plugin:
            let body = try JSONSerialization.data(withJSONObject: ["overview": text])
            try await sendBody("/CascadeServer/Playlists/\(id)/Details", method: "PUT", contentType: "application/json", body: body)
        case .admin:
            // Jellyfin's item update replaces the whole item, so it takes the
            // full fetched item with one field changed, never a partial body.
            var object = try await fullItem(itemId: id).object()
            object["Overview"] = text
            try await updateItem(itemId: id, item: try RawItem(object: object))
        }
    }

    func setPlaylistImage(_ id: String, _ data: Data, route: PlaylistDetails.Route) async throws {
        guard data.count <= PlaylistDetails.maxImageBytes else { throw PlaylistDetails.ImageError.tooLarge }
        guard let type = PlaylistDetails.imageType(data) else { throw PlaylistDetails.ImageError.notAnImage }
        switch route {
        case .plugin:
            try await sendBody("/CascadeServer/Playlists/\(id)/Image", method: "POST", contentType: type, body: data)
        case .admin:
            // Jellyfin's own route reads its body as base64 text, with the
            // image's type as the Content-Type.
            try await sendBody("/Items/\(id)/Images/Primary", method: "POST", contentType: type,
                               body: Data(data.base64EncodedString().utf8))
        }
    }

    func removePlaylistImage(_ id: String, route: PlaylistDetails.Route) async throws {
        try await delete(route == .plugin ? "/CascadeServer/Playlists/\(id)/Image" : "/Items/\(id)/Images/Primary")
    }
}
