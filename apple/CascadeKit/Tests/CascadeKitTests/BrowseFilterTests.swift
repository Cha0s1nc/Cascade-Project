import Testing
@testable import CascadeKit

struct BrowseFilterTests {
    @Test func noFilterSendsNothing() {
        #expect(BrowseFilter().params.isEmpty)
        #expect(!BrowseFilter().isActive)
    }

    @Test func eachFilterBecomesItsParameter() {
        let f = BrowseFilter(favoritesOnly: true, genreId: "g1", decade: 1990, played: .unplayed)
        #expect(f.params == ["isFavorite": "true", "genreIds": "g1",
                             "years": "1990,1991,1992,1993,1994,1995,1996,1997,1998,1999", "isPlayed": "false"])
        #expect(BrowseFilter(played: .played).params == ["isPlayed": "true"])
    }

    @Test func aFilterOverridesButNeverClearsTheScreensOwnParameters() {
        let params: [String: String?] = ["isFavorite": "true", "sortBy": "SortName"]
        #expect(params.applying(BrowseFilter()) == params)
        #expect(params.applying(BrowseFilter(genreId: "g")) == ["isFavorite": "true", "sortBy": "SortName", "genreIds": "g"])
    }

    @Test func decadesAreTheOnesPresentNewestFirst() {
        #expect(BrowseFilter.decades([1975, 1982, 1998, 2004, 2011, 2019, 2020, 2023, 0]) == [2020, 2010, 2000, 1990, 1980, 1970])
        #expect(BrowseFilter.decades([]).isEmpty)
    }

    @Test func storedFormRoundTripsAndJunkIsNoFilter() {
        let f = BrowseFilter(favoritesOnly: true, genreId: "g1", decade: 1990, played: .played)
        #expect(BrowseFilter(rawValue: f.rawValue) == f)
        #expect(BrowseFilter(rawValue: BrowseFilter().rawValue) == BrowseFilter())
        #expect(BrowseFilter(rawValue: "junk") == nil)
        #expect(BrowseFilter(rawValue: "1|g|1990|sideways") == nil)
    }
}
