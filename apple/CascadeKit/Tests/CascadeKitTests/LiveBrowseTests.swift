import Testing
import Foundation
@testable import CascadeKit

// The queries the Mac browsing screens added: filters by genre name, decade,
// the per-kind search with its caps, and video scoped to libraries. Each is
// sent to a real server because a wrong parameter name is ignored, not
// rejected: the symptom is an unfiltered list.
//
// Skipped unless CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set.

@Suite("Live browsing", .enabled(if: liveCredentials != nil))
struct LiveBrowseTests {

    private func client() async throws -> JellyfinClient {
        try await LiveSession.shared.connect().0
    }

    @Test func albumsFilterByGenreName() async throws {
        let client = try await client()
        let all = try await client.albums(limit: 200)
        let names = try await client.genres().compactMap(\.name)
        let genre = try #require(names.first, "the server has no music genres")
        let some = try await client.albums(limit: 200, filter: BrowseFilter(genre: genre))
        #expect(!some.isEmpty)
        #expect(some.count <= all.count)
        // A name nothing has returns nothing, which is how to tell the
        // parameter was read and not ignored.
        let none = try await client.albums(limit: 200, filter: BrowseFilter(genre: "No Such Genre"))
        #expect(none.isEmpty, "the genres parameter appears to be ignored")
    }

    // No artist genre filter: Jellyfin filters artists by the artist's own
    // genre metadata, which is empty for most (checked on 10.11.11, where every
    // artist has none, so any genre returned nothing). The desktop offers none
    // for artists either.

    @Test func artistsSortByDateAdded() async throws {
        let client = try await client()
        let byName = try await client.artists(limit: 50)
        let byDate = try await client.artists(limit: 50, sortBy: ArtistSortField.added.serverSortBy,
                                              sortOrder: "Descending")
        #expect(byName.count == byDate.count)
    }

    @Test func decadeFilterNarrowsToItsYears() async throws {
        let client = try await client()
        let years = try await client.years(of: "MusicAlbum")
        let decade = try #require(BrowseFilter.decades(years).first, "no album has a year")
        let albums = try await client.albums(limit: 200, filter: BrowseFilter(decade: decade))
        #expect(!albums.isEmpty)
        #expect(try await client.albums(limit: 200, filter: BrowseFilter(decade: 1800)).isEmpty)
    }

    @Test func searchRunsEachKindUnderItsOwnCap() async throws {
        let client = try await client()
        // "i" is in a title, an album and an artist of the generated library.
        let results = try await client.searchEverything("i")
        #expect(results.songs.count <= 10)
        #expect(results.albums.count <= 8)
        #expect(results.artists.count <= 8)
        #expect(results.songs.allSatisfy { $0.type == "Audio" })
        #expect(results.albums.allSatisfy { $0.type == "MusicAlbum" })
        #expect(results.artists.allSatisfy { $0.type == "MusicArtist" })
        #expect(!results.songs.isEmpty && !results.albums.isEmpty && !results.artists.isEmpty)
        // No video libraries given, so none are searched.
        #expect(results.movies.isEmpty && results.shows.isEmpty)
        #expect(try await client.searchEverything("   ").isEmpty)
    }

    @Test func videoLibrariesAreFoundByCollectionType() async throws {
        let (movies, shows) = try await client().videoLibraries()
        #expect(movies.allSatisfy { $0.collectionType == "movies" })
        #expect(shows.allSatisfy { $0.collectionType == "tvshows" })
    }

    @Test func videoGroupsAreOnePerLibraryAndFilterByGenre() async throws {
        let client = try await client()
        let (movieLibs, showLibs) = try await client.videoLibraries()
        let movieIds = movieLibs.map(\.id)
        let groups = try await client.videoGroups(type: "Movie", libraryIds: movieIds)
        #expect(groups.count == max(1, movieIds.count))
        let movies = groups.flatMap(\.items)
        #expect(movies.allSatisfy { $0.type == "Movie" })
        let shows = try await client.videoGroups(type: "Series", libraryIds: showLibs.map(\.id)).flatMap(\.items)
        #expect(shows.allSatisfy { $0.type == "Series" })

        // Unscoped is one group with no library id.
        let unscoped = try await client.videoGroups(type: "Movie", libraryIds: [])
        #expect(unscoped.count == 1 && unscoped[0].libraryId.isEmpty)

        if let genre = try await client.genreNames(types: "Movie", libraryIds: movieIds).first {
            let filtered = try await client.videoGroups(type: "Movie", libraryIds: movieIds,
                                                        filter: BrowseFilter(genre: genre)).flatMap(\.items)
            #expect(!filtered.isEmpty)
            #expect(filtered.allSatisfy { $0.genres?.contains(genre) == true })
        }
        let none = try await client.videoGroups(type: "Movie", libraryIds: movieIds,
                                                filter: BrowseFilter(genre: "No Such Genre")).flatMap(\.items)
        #expect(none.isEmpty)
    }

    @Test func videoSearchFindsAMovieByItsName() async throws {
        let client = try await client()
        let (movieLibs, showLibs) = try await client.videoLibraries()
        let movies = try await client.videoGroups(type: "Movie", libraryIds: movieLibs.map(\.id)).flatMap(\.items)
        let movie = try #require(movies.first, "the test server has no movies")
        let word = String((movie.name ?? "").prefix(4))
        let found = try await client.searchEverything(word, movieLibraries: movieLibs.map(\.id),
                                                      showLibraries: showLibs.map(\.id))
        #expect(found.movies.contains { $0.id == movie.id })
        #expect(found.movies.count <= 8 && found.shows.count <= 8)
    }

    @Test func continueWatchingIsAcceptedAndHasOneCardPerSeries() async throws {
        let client = try await client()
        let (movieLibs, showLibs) = try await client.videoLibraries()
        let items = try await client.continueWatchingMerged(movieIds: movieLibs.map(\.id),
                                                            showIds: showLibs.map(\.id))
        let series = items.filter { $0.type == "Episode" }.compactMap(\.seriesId)
        #expect(Set(series).count == series.count)
        #expect(items.count <= 24)
    }

    @Test func videoYearsAndGenresListWhatIsThere() async throws {
        let client = try await client()
        let (movieLibs, _) = try await client.videoLibraries()
        let years = try await client.years(of: "Movie", libraryIds: movieLibs.map(\.id))
        #expect(years.allSatisfy { $0 > 0 })
        _ = try await client.genreNames(types: "Series")
    }
}
