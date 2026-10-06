import Testing
import Foundation
@testable import CascadeKit

// Every library write the context menus and the metadata editor make, against
// a real server and read back. Skipped unless CASCADE_SERVER / CASCADE_USER /
// CASCADE_PASS are set. Anything changed is put back; the only thing deleted
// is a playlist this test made.
@Suite("Live library actions", .enabled(if: liveCredentials != nil), .serialized)
struct LiveActionsTests {
    private func freshPlaylist(_ client: JellyfinClient, tracks: [JfItem]) async throws -> String {
        try await client.createPlaylist(name: "cascade-test-\(UUID().uuidString.prefix(8))", itemIds: tracks.map(\.id))
    }

    @Test func bulkSaveReordersAndRemovesInOneWriteAndRenameKeepsContents() async throws {
        let client = try await LiveSession.shared.connect().0
        let tracks = Array(try await client.songs(limit: 4).prefix(4))
        try #require(tracks.count == 4)
        let id = try await freshPlaylist(client, tracks: tracks)
        defer { Task { [client] in try? await client.deleteItem(id) } }

        var entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == tracks.map(\.id))

        // Move rows 2 and 4 to the top: one whole-Ids POST.
        let selected: Set<String> = [entries[1].entryId, entries[3].entryId]
        try await client.setPlaylistItems(id, itemIds: PlaylistEdit.movingToTop(entries, selected: selected).map(\.id))
        entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == [tracks[1].id, tracks[3].id, tracks[0].id, tracks[2].id])

        try await client.setPlaylistItems(id, itemIds: PlaylistEdit.movingToBottom(entries, selected: [entries[0].entryId]).map(\.id))
        entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == [tracks[3].id, tracks[0].id, tracks[2].id, tracks[1].id])

        // Remove two in one write.
        try await client.setPlaylistItems(id, itemIds: PlaylistEdit.removing(entries, selected: [entries[0].entryId, entries[2].entryId]).map(\.id))
        entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == [tracks[0].id, tracks[1].id])

        // Name and public flag together, contents untouched, read back from the right place.
        let before = try await client.playlistInfo(id)
        try await client.updatePlaylist(id, name: "cascade-test-renamed", isPublic: !before.isPublic)
        let after = try await client.playlistInfo(id)
        #expect(after.isPublic == !before.isPublic)
        #expect(try await client.tracks(inPlaylist: id).map(\.id) == [tracks[0].id, tracks[1].id])
        #expect(try await client.items(ids: [id]).first?.name == "cascade-test-renamed")
        #expect(after.canEdit, "the owner can edit")
    }

    @Test func aDragMoveWorksOnAFreshlyBulkSavedPlaylist() async throws {
        let client = try await LiveSession.shared.connect().0
        let tracks = Array(try await client.songs(limit: 3).prefix(3))
        try #require(tracks.count == 3)
        let id = try await freshPlaylist(client, tracks: tracks)
        defer { Task { [client] in try? await client.deleteItem(id) } }
        // Reverse by bulk, then drag the first row to the end: the entry ids
        // must still be good after a whole-Ids write.
        try await client.setPlaylistItems(id, itemIds: tracks.reversed().map(\.id))
        var entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == tracks.reversed().map(\.id))
        try await client.movePlaylistEntry(id, entryId: entries[0].entryId, to: playlistMoveIndex(from: 0, toOffset: 3))
        entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == [tracks[1].id, tracks[0].id, tracks[2].id])
    }

    @Test func markPlayedAndUnplayedReadBack() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        let original = try await client.items(ids: [track.id]).first?.userData?.played ?? false
        defer { Task { [client] in try? await client.setPlayed(original, itemId: track.id) } }
        try await client.setPlayed(!original, itemId: track.id)
        #expect(try await client.items(ids: [track.id]).first?.userData?.played == !original)
        try await client.setPlayed(original, itemId: track.id)
        #expect((try await client.items(ids: [track.id]).first?.userData?.played ?? false) == original)
    }

    @Test func theMetadataEditorPostsTheWholeItemAndOnlyTheEightFieldsChange() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        let originalRaw = try await client.fullItem(itemId: track.id)
        let original = try originalRaw.object()
        // Put back whatever happens below, from the item as fetched.
        defer { Task { [client] in try? await client.updateItem(itemId: track.id, item: originalRaw) } }

        var fields = MetadataEdit.fields(from: original)
        fields.name = "cascade metadata test"
        fields.genres = "Electronic, Cascade Test"
        fields.year = "1999"
        fields.disc = "2"
        try await client.updateItem(itemId: track.id,
                                    item: try RawItem(object: try MetadataEdit.apply(fields, to: original)))

        let changed = try await client.fullItem(itemId: track.id).object()
        #expect(changed["Name"] as? String == "cascade metadata test")
        #expect(changed["ProductionYear"] as? Int == 1999)
        #expect(changed["ParentIndexNumber"] as? Int == 2)
        #expect((changed["Genres"] as? [String])?.contains("Cascade Test") == true)
        // Nothing the form does not show was blanked.
        #expect(changed["Album"] as? String == original["Album"] as? String)
        #expect(changed["AlbumArtist"] as? String == original["AlbumArtist"] as? String)
        #expect(changed["Artists"] as? [String] == original["Artists"] as? [String])
        #expect(changed["IndexNumber"] as? Int == original["IndexNumber"] as? Int)
        #expect(changed["RunTimeTicks"] as? Int == original["RunTimeTicks"] as? Int)
        #expect(changed["Path"] as? String == original["Path"] as? String)

        // And back, read to confirm the restore took.
        try await client.updateItem(itemId: track.id, item: originalRaw)
        let restored = try await client.fullItem(itemId: track.id).object()
        #expect(restored["Name"] as? String == original["Name"] as? String)
        #expect(restored["ProductionYear"] as? Int == original["ProductionYear"] as? Int)
        #expect(restored["ParentIndexNumber"] as? Int == original["ParentIndexNumber"] as? Int)
        #expect(restored["Genres"] as? [String] == original["Genres"] as? [String])
    }

    @Test func refreshMetadataIsAcceptedForAnAdmin() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        try await client.refreshMetadata(itemId: track.id)
    }

    @Test func mediaDetailGivesTheFileFactsTheSheetShows() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        let rows = MediaInfo.rows(try await client.mediaDetail(itemId: track.id))
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["Title"] == track.name)
        #expect(byLabel["Codec"] != nil && byLabel["Codec"] != "-")
        #expect(byLabel["Size"] != nil && byLabel["Size"] != "-", "size comes from the media source")
        #expect(byLabel["Duration"]?.contains(":") == true)
    }

    @Test func deleteRemovesAnItemThisTestMadeAndAMissingOneIsRefused() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        let id = try await freshPlaylist(client, tracks: [track])
        #expect(try await client.playlists().contains { $0.id == id })
        try await client.deleteItem(id)
        #expect(try await !client.playlists().contains { $0.id == id })
        await #expect(throws: JellyfinError.self) { try await client.deleteItem(id) }
    }

    @Test func downloadSavesTheOriginalFileAndAnErrorPageNeverBecomesOne() async throws {
        let client = try await LiveSession.shared.connect().0
        let track = try #require(try await client.songs(limit: 1).first)
        let size = try #require(try await client.mediaDetail(itemId: track.id).mediaSources?.first?.size)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }
        try await client.downloadItem(itemId: track.id, to: dest)
        let written = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int
        #expect(written == size)

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: missing) }
        await #expect(throws: JellyfinError.self) {
            try await client.downloadItem(itemId: "00000000000000000000000000000000", to: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func aNonAdminsPolicyAndRefusals() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let server = e["CASCADE_SERVER"], let user = e["CASCADE_GUEST_USER"], let pass = e["CASCADE_GUEST_PASS"] else { return }
        let admin = try await LiveSession.shared.connect().0
        #expect(Permissions.isAdmin(policy: try await admin.userPolicy()))
        #expect(Permissions.canDeleteMedia(policy: try await admin.userPolicy()))

        let deviceId = "cascade-swift-tests-guest-actions"
        let auth = try await authenticate(serverUrl: server, username: user, password: pass,
                                          appVersion: "0.1.0", deviceId: deviceId)
        let guest = JellyfinClient(config: ServerConfig(url: server, token: auth.accessToken,
                                                        userId: auth.user.id, deviceId: deviceId))
        let policy = try await guest.userPolicy()
        #expect(!Permissions.isAdmin(policy: policy))
        // Whatever the guest may delete, the server is the one that decides: an
        // admin-only write comes back as an error, never as success.
        let track = try #require(try await admin.songs(limit: 1).first)
        await #expect(throws: JellyfinError.self) { try await guest.refreshMetadata(itemId: track.id) }
        let original = try await admin.fullItem(itemId: track.id)
        await #expect(throws: JellyfinError.self) { try await guest.updateItem(itemId: track.id, item: original) }
        #expect((try await admin.fullItem(itemId: track.id).object()["Name"] as? String) == track.name)
    }
}
