import Testing
import Foundation
@testable import CascadeKit

struct PlaylistEditingTests {
    @Test func onMoveOffsetsBecomeTheServersFinalIndex() {
        // Down: SwiftUI counts the slot below the target before removal.
        #expect(playlistMoveIndex(from: 0, toOffset: 3) == 2)
        #expect(playlistMoveIndex(from: 1, toOffset: 2) == 1)
        // Up: nothing above moves, so the offset is the index.
        #expect(playlistMoveIndex(from: 3, toOffset: 0) == 0)
        #expect(playlistMoveIndex(from: 2, toOffset: 1) == 1)
    }

    @Test func aRowIsIdentifiedByItsEntryIdWhenThereIsOne() {
        var entry = JfItem(id: "track")
        #expect(entry.entryId == "track")
        entry.playlistItemId = "entry"
        #expect(entry.entryId == "entry")
    }

    @Test func renameSendsOnlyTheName() throws {
        // Sending Ids (even empty) would replace the playlist's contents.
        let json = String(decoding: try JSON.encoder.encode(PlaylistUpdate(name: "Road Trip")), as: UTF8.self)
        #expect(json == #"{"Name":"Road Trip"}"#)
    }

    @Test func createIsAnAudioPlaylistForThisUser() throws {
        let data = try JSON.encoder.encode(NewPlaylist(name: "A", ids: ["1"], userId: "u"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["Name"] as? String == "A")
        #expect(object["Ids"] as? [String] == ["1"])
        #expect(object["UserId"] as? String == "u")
        #expect(object["MediaType"] as? String == "Audio")
    }
}
