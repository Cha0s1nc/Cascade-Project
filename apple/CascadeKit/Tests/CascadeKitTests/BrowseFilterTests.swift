import Testing
import Foundation
@testable import CascadeKit

struct BrowseFilterTests {
    @Test func noFilterSendsNothing() {
        #expect(BrowseFilter().params.isEmpty)
        #expect(!BrowseFilter().isActive)
    }

    @Test func eachFilterBecomesItsParameter() {
        let f = BrowseFilter(favoritesOnly: true, genre: "Rock", decade: 1990, played: .unplayed)
        #expect(f.params == ["isFavorite": "true", "genres": "Rock",
                             "years": "1990,1991,1992,1993,1994,1995,1996,1997,1998,1999", "isPlayed": "false"])
        #expect(BrowseFilter(played: .played).params == ["isPlayed": "true"])
    }

    @Test func aFilterOverridesButNeverClearsTheScreensOwnParameters() {
        let params: [String: String?] = ["isFavorite": "true", "sortBy": "SortName"]
        #expect(params.applying(BrowseFilter()) == params)
        #expect(params.applying(BrowseFilter(genre: "g")) == ["isFavorite": "true", "sortBy": "SortName", "genres": "g"])
    }

    @Test func decadesAreTheOnesPresentNewestFirst() {
        #expect(BrowseFilter.decades([1975, 1982, 1998, 2004, 2011, 2019, 2020, 2023, 0]) == [2020, 2010, 2000, 1990, 1980, 1970])
        #expect(BrowseFilter.decades([]).isEmpty)
    }

    @Test func storedFormRoundTripsAndJunkIsNoFilter() {
        let f = BrowseFilter(favoritesOnly: true, genre: "Rock", decade: 1990, played: .played)
        #expect(BrowseFilter(rawValue: f.rawValue) == f)
        #expect(BrowseFilter(rawValue: BrowseFilter().rawValue) == BrowseFilter())
        #expect(BrowseFilter(rawValue: "junk") == nil)
        #expect(BrowseFilter(rawValue: "1|g|1990|sideways") == nil)
    }
}

// Ported from test/library-browse.test.ts (normalizeLibraryPrefs).
struct LibraryPrefsTests {
    @Test func corruptedStoreValuesFallBackToDefaultsNeverGarbage() {
        #expect(LibraryPrefs(stored: nil) == nil)
        #expect(LibraryPrefs(stored: "not json") == nil)
        #expect(LibraryPrefs(stored: "[1,2,3]") == nil)
        // A usable object with bad parts keeps the defaults for those parts.
        #expect(LibraryPrefs(stored: #"{"field":"bogus"}"#)?.sortField(default: AlbumSortField.name) == .name)
        #expect(LibraryPrefs(stored: #"{"dir":"sideways"}"#)?.direction == .ascending)
        #expect(LibraryPrefs(stored: #"{"decade":"1990"}"#)?.filter.decade == nil)
        #expect(LibraryPrefs(stored: #"{"decade":true}"#)?.filter.decade == nil)
        #expect(LibraryPrefs(stored: #"{"played":"maybe"}"#)?.filter.played == .any)
        #expect(LibraryPrefs(stored: #"{"genre":"a|b"}"#)?.filter.genre == nil)
    }

    @Test func aValidValueRoundTrips() {
        let json = #"{"field":"year","dir":"desc","favorite":true,"genre":"Jazz","decade":1990,"played":"played"}"#
        let prefs = LibraryPrefs(stored: json)
        #expect(prefs == LibraryPrefs(field: "year", direction: .descending,
                                      filter: BrowseFilter(favoritesOnly: true, genre: "Jazz", decade: 1990, played: .played)))
        #expect(LibraryPrefs(stored: prefs!.stored) == prefs)
    }

    @Test func writtenInTheDesktopsShapeWithNulls() throws {
        let object = try JSONSerialization.jsonObject(with: Data(LibraryPrefs().stored.utf8)) as? [String: Any]
        #expect(object?["field"] as? String == "name")
        #expect(object?["dir"] as? String == "asc")
        #expect(object?["favorite"] as? Bool == false)
        #expect(object?["genre"] is NSNull)
        #expect(object?["decade"] is NSNull)
        #expect(object?["played"] is NSNull)
    }

    @Test func aFieldTheScreenDoesNotOfferReadsAsItsDefault() {
        let prefs = LibraryPrefs(field: "count")
        #expect(prefs.sortField(default: AlbumSortField.name) == .name)
        #expect(LibraryPrefs(field: "added").sortField(default: ArtistSortField.name) == .added)
    }
}
