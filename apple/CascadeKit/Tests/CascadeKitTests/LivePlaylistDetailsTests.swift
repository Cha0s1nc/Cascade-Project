import Foundation
import Testing
@testable import CascadeKit

// A playlist's picture and description against a real server, both paths:
// the Cascade Server plugin (the owner may) and Jellyfin's own routes (admins
// only). Skipped unless CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set;
// the plugin half also needs the plugin's playlist-edit capability. Deletes
// only playlists it made.
@Suite("Live playlist details", .enabled(if: liveCredentials != nil), .serialized)
struct LivePlaylistDetailsTests {
    /// The smallest valid PNG: one transparent pixel.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private func hasPicture(_ client: JellyfinClient, _ id: String) async -> Bool {
        (try? await client.getData("/Items/\(id)/Images/Primary")) != nil
    }

    private func guest() async throws -> JellyfinClient? {
        let e = ProcessInfo.processInfo.environment
        guard let server = e["CASCADE_SERVER"], let user = e["CASCADE_GUEST_USER"], let pass = e["CASCADE_GUEST_PASS"] else { return nil }
        let deviceId = "cascade-swift-tests-guest-playlist-details"
        let auth = try await authenticate(serverUrl: server, username: user, password: pass, appVersion: "0.1.0", deviceId: deviceId)
        return JellyfinClient(config: ServerConfig(url: server, token: auth.accessToken, userId: auth.user.id, deviceId: deviceId))
    }

    @Test func anAdminSetsBothThroughJellyfin() async throws {
        let client = try await LiveSession.shared.connect().0
        let id = try await client.createPlaylist(name: "cascade-test-details-admin")
        defer { Task { [client] in try? await client.deleteItem(id) } }
        try await client.setPlaylistOverview(id, "Songs for the drive", route: .admin)
        #expect(try await client.playlistOverview(id) == "Songs for the drive")
        try await client.setPlaylistImage(id, png, route: .admin)
        #expect(await hasPicture(client, id))
        try await client.removePlaylistImage(id, route: .admin)
        #expect(!(await hasPicture(client, id)))
        try await client.setPlaylistOverview(id, "", route: .admin)
        #expect(try await client.playlistOverview(id) == "")
    }

    @Test func anOwnerWhoIsNotAnAdminSetsThemThroughThePlugin() async throws {
        let admin = try await LiveSession.shared.connect().0
        let (_, api, info) = await admin.probeCascadePlugin()
        guard api != nil, info.capabilities.contains("playlist-edit") else { return }   // no plugin here
        guard let guest = try await guest() else { return }
        let id = try await guest.createPlaylist(name: "cascade-test-details-owner")
        defer { Task { [admin] in try? await admin.deleteItem(id) } }
        try await guest.setPlaylistOverview(id, "Mine", route: .plugin)
        #expect(try await guest.playlistOverview(id) == "Mine")
        try await guest.setPlaylistImage(id, png, route: .plugin)
        #expect(await hasPicture(guest, id))
        try await guest.removePlaylistImage(id, route: .plugin)
        #expect(!(await hasPicture(guest, id)))
        // Jellyfin's own route still refuses the same owner.
        await #expect(throws: JellyfinError.self) { try await guest.setPlaylistOverview(id, "x", route: .admin) }
    }

    @Test func someoneElsesPlaylistIsRefused() async throws {
        let admin = try await LiveSession.shared.connect().0
        let (_, api, info) = await admin.probeCascadePlugin()
        guard api != nil, info.capabilities.contains("playlist-edit"), let guest = try await guest() else { return }
        let id = try await admin.createPlaylist(name: "cascade-test-details-not-yours")
        defer { Task { [admin] in try? await admin.deleteItem(id) } }
        await #expect(throws: JellyfinError.self) { try await guest.setPlaylistOverview(id, "x", route: .plugin) }
        await #expect(throws: JellyfinError.self) { try await guest.setPlaylistImage(id, png, route: .plugin) }
    }

    @Test func aFileThatIsNotAnImageNeverLeaves() async throws {
        let client = try await LiveSession.shared.connect().0
        await #expect(throws: PlaylistDetails.ImageError.self) {
            try await client.setPlaylistImage("00000000000000000000000000000000", Data("GIF89a".utf8), route: .admin)
        }
    }
}
