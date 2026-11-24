import Foundation
import Testing
@testable import CascadeKit

/// The song's own artists for display, as the desktop's trackArtist and Flutter's Song.artist.
@Suite struct SongArtistTests {
    private func item(_ json: String) throws -> JfItem {
        try JSON.decoder.decode(JfItem.self, from: Data(json.utf8))
    }

    @Test func theSongsOwnArtistsWinOverTheAlbums() throws {
        #expect(try item(#"{"Id":"1","AlbumArtist":"The Script","Artists":["The Script","will.i.am"]}"#).songArtist == "The Script, will.i.am")
        #expect(try item(#"{"Id":"2","AlbumArtist":"Various Artists","Artists":["Queen"]}"#).songArtist == "Queen")
    }

    @Test func anUnsplitTagReadsAsTwoArtistsEachOnce() throws {
        #expect(try item(#"{"Id":"3","Artists":["The Script; will.i.am","will.i.am"]}"#).songArtist == "The Script, will.i.am")
        #expect(try item(#"{"Id":"4","AlbumArtist":"Luco; No/Me"}"#).albumArtistLine == "Luco, No/Me")
    }

    @Test func theAlbumArtistOnlyWhenNoneAreTagged() throws {
        #expect(try item(#"{"Id":"5","AlbumArtist":"Someone","Artists":[]}"#).songArtist == "Someone")
        #expect(try item(#"{"Id":"6"}"#).songArtist == "")
        #expect(try item(#"{"Id":"7"}"#).albumArtistLine == nil)
    }
}
