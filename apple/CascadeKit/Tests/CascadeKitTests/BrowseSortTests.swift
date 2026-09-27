import Testing
@testable import CascadeKit

/// An item that sorts after `rank - 1` and before `rank + 1` on every key the
/// browsing screens use.
private func ranked(_ id: String, _ rank: Int, albumId: String? = nil) -> JfItem {
    var item = JfItem(id: id, name: "Name \(rank)", type: "Audio")
    item.sortName = "name \(rank)"
    item.albumArtist = "Artist \(rank)"
    item.album = "Album \(rank)"
    item.productionYear = 2000 + rank
    item.dateCreated = "2026-0\(rank)-01T00:00:00Z"
    item.userData = JfUserData()
    item.userData?.lastPlayedDate = "2026-0\(rank)-02T00:00:00Z"
    item.albumId = albumId
    return item
}

private func ids(_ items: [JfItem]) -> [String] { items.map(\.id) }

struct BrowseSortTests {
    // A server sort that sortedLikeServer does not know leaves two libraries
    // concatenated instead of interleaved, silently. So every key a screen can
    // ask for must actually reorder.
    @Test func everyServerSortCanBeReproducedAcrossLibraries() {
        let keys = SongSortField.allCases.map(\.serverSortBy)
            + AlbumSortField.allCases.compactMap(\.serverSortBy)
            + PlaylistSortField.allCases.map(\.serverSortBy)
        for key in keys {
            let joined = [ranked("second", 2), ranked("first", 1)]
            #expect(ids(sortedLikeServer(joined, sortBy: key)) == ["first", "second"], "\(key)")
            #expect(ids(sortedLikeServer(joined, sortBy: key, sortOrder: "Descending")) == ["second", "first"], "\(key)")
        }
    }

    @Test func yearsCompareAsNumbersNotText() {
        var old = JfItem(id: "old"); old.productionYear = 999
        var new = JfItem(id: "new"); new.productionYear = 2024
        #expect(ids(sortedLikeServer([new, old], sortBy: "ProductionYear,SortName")) == ["old", "new"])
    }

    @Test func directionMapsToTheServersWords() {
        #expect(SortDirection.ascending.serverValue == "Ascending")
        #expect(SortDirection.descending.serverValue == "Descending")
    }

    @Test func recentlyPlayedAlbumsFollowTheirNewestTrack() {
        // Newest play first: album B, then A (twice), then C.
        let played = [ranked("t1", 1, albumId: "B"), ranked("t2", 2, albumId: "A"),
                      ranked("t3", 3, albumId: "A"), ranked("t4", 4, albumId: "C")]
        #expect(recentlyPlayedAlbumIds(played) == ["B", "A", "C"])
        let albums = [JfItem(id: "A"), JfItem(id: "C"), JfItem(id: "never"), JfItem(id: "B")]
        #expect(ids(albumsByRecentPlay(playedTracks: played, albums: albums)) == ["B", "A", "C"])
    }
}
