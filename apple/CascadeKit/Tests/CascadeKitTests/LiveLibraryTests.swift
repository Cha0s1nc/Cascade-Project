import Testing
import Foundation
@testable import CascadeKit

// Every query a browsing screen makes, run against a real server. These exist
// because the only way to know a parameter shape is right is to send it: a
// wrong sortBy is not an error, it is a list in the wrong order that nobody
// notices for a week.
//
// Skipped unless CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set.


@Suite("Live library", .enabled(if: liveCredentials != nil))
struct LiveLibraryTests {

    private func client() async throws -> JellyfinClient {
        try await LiveSession.shared.connect().0
    }

    @Test func findsAtLeastOneMusicLibrary() async throws {
        let libraries = try await client().musicLibraries()
        #expect(!libraries.isEmpty, "no library with collectionType music")
    }

    @Test func albumsAreAlbumsAndTheSortParameterIsHonoured() async throws {
        let client = try await client()
        let byName = try await client.albums(limit: 20)
        #expect(!byName.isEmpty)
        #expect(byName.allSatisfy { $0.type == "MusicAlbum" })

        // Not compared against a locally sorted copy: Jellyfin's SortName
        // collation is its own (numeric aware, symbols first, articles
        // stripped) and will never match Swift's plain string ordering, so
        // that assertion would only ever test the comparison function.
        //
        // What actually needs checking is that the parameter is being read at
        // all. Jellyfin ignores a sortBy it does not recognise and falls back
        // to a default, so a typo is a silently wrong order rather than an
        // error. Two different sorts returning different lists proves the
        // parameter reached the server.
        let byDate = try await client.recentlyAdded(limit: 20)
        #expect(byName.map(\.id) != byDate.map(\.id), "sortBy appears to be ignored")
    }

    @Test func artistsUseTheAlbumArtistsEndpoint() async throws {
        // Not an item type. Asking /Items for MusicArtist returns every
        // credited artist, which is not the list a music app means.
        let artists = try await client().artists(limit: 20)
        #expect(!artists.isEmpty)
        #expect(artists.allSatisfy { $0.type == "MusicArtist" })
    }

    @Test func songsCarryTheFieldsSortingNeeds() async throws {
        let songs = try await client().songs(limit: 20)
        #expect(!songs.isEmpty)
        #expect(songs.allSatisfy { $0.type == "Audio" })
        // Without fields=DateCreated this is nil and "recently added" silently
        // sorts everything as equal rather than failing.
        #expect(songs.contains { $0.dateCreated != nil })
        #expect(songs.allSatisfy { ($0.runTimeTicks ?? 0) > 0 })
    }

    @Test func albumTracksComeBackInDiscThenTrackOrder() async throws {
        let client = try await client()
        let album = try #require(try await client.albums(limit: 1).first)
        let tracks = try await client.tracks(inAlbum: album.id)
        #expect(!tracks.isEmpty, "album \(album.name ?? album.id) has no tracks")

        // Disc first: a two-disc album sorted on track number alone interleaves
        // the discs, which looks like a shuffled album.
        let ordering = tracks.map { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) }
        let ascending = zip(ordering, ordering.dropFirst()).allSatisfy { $0 <= $1 }
        #expect(ascending, "tracks out of order: \(ordering)")
    }

    @Test func anArtistsAlbumsAndTracksResolve() async throws {
        let client = try await client()
        let artist = try #require(try await client.artists(limit: 1).first)
        let albums = try await client.albums(byArtist: artist.id)
        let tracks = try await client.tracks(byArtist: artist.id, limit: 10)
        // An album artist with no albums would mean albumArtistIds is the wrong
        // parameter name, which is a silent empty screen rather than an error.
        #expect(!albums.isEmpty, "no albums for album artist \(artist.name ?? artist.id)")
        #expect(!tracks.isEmpty, "no tracks for artist \(artist.name ?? artist.id)")
    }

    @Test func searchMatchesAcrossAllThreeTypes() async throws {
        let results = try await client().search("a", limit: 60)
        #expect(!results.isEmpty)
        let types = Set(results.compactMap(\.type))
        #expect(types.isSubset(of: ["Audio", "MusicAlbum", "MusicArtist"]),
                "search returned unexpected types: \(types)")
    }

    @Test func emptySearchNeverHitsTheServer() async throws {
        #expect(try await client().search("   ").isEmpty)
    }

    @Test func homeRowsAllReturnSomething() async throws {
        let client = try await client()
        #expect(!(try await client.recentlyAdded(limit: 10)).isEmpty)
        // These two filter on IsPlayed, so they are empty on a fresh account
        // rather than broken. Assert the call is accepted, not that it is full.
        _ = try await client.recentlyPlayed(limit: 10)
        _ = try await client.frequentlyPlayed(limit: 10)
    }

    @Test func playedAndFavouriteWritesAreAcceptedAndReversible() async throws {
        let client = try await client()
        let track = try #require(try await client.songs(limit: 1).first)

        // These throw on a bad status. The desktop bug being guarded against is
        // a 403 that looked exactly like success.
        try await client.setFavorite(true, itemId: track.id)
        try await client.setFavorite(false, itemId: track.id)

        let wasPlayed = track.userData?.played ?? false
        try await client.setPlayed(!wasPlayed, itemId: track.id)
        try await client.setPlayed(wasPlayed, itemId: track.id)
    }
}
