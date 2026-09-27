import Testing
import Foundation
@testable import CascadeKit

// Every playlist write, against a real server, read back after each step.
// Skipped unless CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set.
// Makes its own uniquely named playlist and deletes it at the end.
@Suite("Live playlists", .enabled(if: liveCredentials != nil))
struct LivePlaylistTests {
    @Test func createAddRenameMoveRemoveDelete() async throws {
        let client = try await LiveSession.shared.connect().0
        let tracks = Array(try await client.songs(limit: 3).prefix(3))  // limit is per library
        try #require(tracks.count == 3)
        let name = "cascade-test-\(UUID().uuidString.prefix(8))"

        let id = try await client.createPlaylist(name: name, itemIds: [tracks[0].id])
        var deleted = false
        defer {
            if !deleted { Task { [client] in try? await client.deletePlaylist(id) } }
        }
        #expect(try await client.playlists().contains { $0.id == id && $0.name == name })

        try await client.addToPlaylist(id, itemIds: [tracks[1].id, tracks[2].id])
        var entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == tracks.map(\.id))
        #expect(entries.allSatisfy { $0.playlistItemId != nil }, "entries carry PlaylistItemId")

        // Renaming must not touch the contents.
        try await client.renamePlaylist(id, to: name + " renamed")
        #expect(try await client.playlists().first { $0.id == id }?.name == name + " renamed")
        #expect(try await client.tracks(inPlaylist: id).count == 3)

        // First entry to the end, as a drag from row 0 to below row 2 sends it.
        try await client.movePlaylistEntry(id, entryId: entries[0].entryId,
                                           to: playlistMoveIndex(from: 0, toOffset: 3))
        entries = try await client.tracks(inPlaylist: id)
        #expect(entries.map(\.id) == [tracks[1].id, tracks[2].id, tracks[0].id])

        try await client.removeFromPlaylist(id, entryIds: [entries[1].entryId])
        #expect(try await client.tracks(inPlaylist: id).map(\.id) == [tracks[1].id, tracks[0].id])

        try await client.deletePlaylist(id)
        deleted = true
        #expect(try await !client.playlists().contains { $0.id == id })
    }

    @Test func aRefusedWriteThrows() async throws {
        let client = try await LiveSession.shared.connect().0
        await #expect(throws: JellyfinError.self) {
            try await client.renamePlaylist("00000000000000000000000000000000", to: "nope")
        }
    }
}
