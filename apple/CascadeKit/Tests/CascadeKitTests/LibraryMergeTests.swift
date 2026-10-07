import Testing
@testable import CascadeKit

// Ported case for case from the desktop's dedupeById tests in
// test/jellyfin.test.ts, so the two apps agree on what counts as a copy.

private func song(_ id: String, _ name: String, _ artist: String, seconds: Double,
                  library: Int, kbps: Int? = nil) -> JfItem {
    var item = JfItem(id: id, name: name, type: "Audio", runTimeTicks: Int(seconds * 10_000_000))
    item.artists = [artist]
    item.sourceLibrary = library
    if let kbps { item.mediaSources = [JfMediaSourceRef(bitrate: kbps * 1000)] }
    return item
}

private func album(_ id: String, _ name: String, _ albumArtist: String, library: Int, tracks: Int? = nil) -> JfItem {
    var item = JfItem(id: id, name: name, type: "MusicAlbum")
    item.albumArtist = albumArtist
    item.childCount = tracks
    item.sourceLibrary = library
    return item
}

private func ids(_ items: [JfItem]) -> [String] { items.map(\.id) }

struct LibraryMergeTests {
    @Test func theSameSongInTwoLibrariesAppearsOnce() {
        let merged = mergeLibraryCopies([
            song("a1", "Mr. Brightside", "The Killers", seconds: 222, library: 0),
            song("a2", "Sober", "Letdown.", seconds: 216, library: 0),
            song("b1", "mr brightside", "the killers", seconds: 223, library: 1),         // same song: dropped
            song("b2", "Mr. Brightside (Live)", "The Killers", seconds: 240, library: 1), // a different cut: kept
            song("b3", "Sober", "Letdown.", seconds: 300, library: 1),                    // 84s longer: kept
        ])
        #expect(ids(merged) == ["a1", "a2", "b2", "b3"])
    }

    @Test func copiesInsideOneLibraryAreLeftAlone() {
        let merged = mergeLibraryCopies([
            song("1", "Home", "Phillip Phillips", seconds: 209, library: 0),
            song("2", "Home", "Phillip Phillips", seconds: 209, library: 0),
        ])
        #expect(merged.count == 2)
    }

    @Test func albumsMatchOnNameAndAlbumArtist() {
        let merged = mergeLibraryCopies([
            album("a", "A Fever You Can’t Sweat Out", "Panic! At The Disco", library: 0),
            album("b", "A Fever You Can't Sweat Out", "Panic! at the Disco", library: 1),
            album("c", "Pretty. Odd.", "Panic! At The Disco", library: 1),
        ])
        #expect(ids(merged) == ["a", "c"])
    }

    @Test func otherTypesOnlyMergeById() {
        var one = JfItem(id: "1", name: "Road trip", type: "Playlist"); one.sourceLibrary = 0
        var two = JfItem(id: "2", name: "Road trip", type: "Playlist"); two.sourceLibrary = 1
        #expect(mergeLibraryCopies([one, two, one]).count == 2)
    }

    @Test func theHigherBitrateCopyWinsInTheFirstCopysPlace() {
        let merged = mergeLibraryCopies([
            song("mp3", "Idol", "YOASOBI", seconds: 213, library: 0, kbps: 320),
            song("x", "Other", "Someone", seconds: 100, library: 0),
            song("flac", "Idol", "YOASOBI", seconds: 213, library: 1, kbps: 1100),
            song("aac", "Idol", "YOASOBI", seconds: 213, library: 2, kbps: 256),
        ])
        #expect(ids(merged) == ["flac", "x"])
    }

    @Test func ofTwoCopiesOfAnAlbumTheOneWithMoreTracksWins() {
        // Real case from a Jellyfin test server: Night Drive whole in one
        // library, one song of it in another; keeping the one-song copy hid
        // the rest of the album.
        let partial = album("partial", "Night Drive", "Aurora Lane", library: 0, tracks: 1)
        let whole = album("whole", "Night Drive", "Aurora Lane", library: 1, tracks: 3)
        #expect(ids(mergeLibraryCopies([partial, whole])) == ["whole"])
        var wholeFirst = whole; wholeFirst.sourceLibrary = 0
        var partialSecond = partial; partialSecond.sourceLibrary = 1
        #expect(ids(mergeLibraryCopies([wholeFirst, partialSecond])) == ["whole"])
    }

    @Test func anArtistInTwoLibrariesAppearsOnce() {
        // Jellyfin 12 gives the same artist a different id in every library.
        func artist(_ id: String, _ name: String, _ library: Int) -> JfItem {
            var item = JfItem(id: id, name: name, type: "MusicArtist"); item.sourceLibrary = library; return item
        }
        let merged = mergeLibraryCopies([
            artist("42585974", "Aurora Lane", 0),
            artist("98eed3bf", "aurora lane", 1),
            artist("d15fdbee", "Aurora Lane; Kite Echo", 1),
        ])
        #expect(ids(merged) == ["42585974", "d15fdbee"])
    }

    @Test func mergingTwiceChangesNothing() {
        // loadPaged re-merges everything loaded so far on every page.
        let items = [
            song("mp3", "Idol", "YOASOBI", seconds: 213, library: 0, kbps: 320),
            song("flac", "Idol", "YOASOBI", seconds: 213, library: 1, kbps: 1100),
        ]
        #expect(ids(mergeLibraryCopies(mergeLibraryCopies(items))) == ids(mergeLibraryCopies(items)))
    }

    @Test func librariesArePutBackInOneOrder() {
        func named(_ id: String, _ name: String, sortName: String? = nil, library: Int) -> JfItem {
            var item = JfItem(id: id, name: name, type: "MusicAlbum"); item.sortName = sortName; item.sourceLibrary = library; return item
        }
        // Each library arrives sorted on its own, one after the other.
        let joined = [named("1", "Daybreak", library: 0), named("2", "Night Drive", library: 0),
                      named("3", "Only Here", library: 1), named("4", "The Album", sortName: "Album", library: 1)]
        #expect(ids(sortedLikeServer(joined, sortBy: "SortName")) == ["4", "1", "2", "3"])
        #expect(ids(sortedLikeServer(joined, sortBy: "SortName", sortOrder: "Descending")) == ["3", "2", "1", "4"])
    }

    @Test func anOrderItCannotReproduceIsLeftAlone() {
        let items = [JfItem(id: "b", name: "B"), JfItem(id: "a", name: "A")]
        #expect(ids(sortedLikeServer(items, sortBy: "ParentIndexNumber,IndexNumber")) == ["b", "a"])
        #expect(ids(sortedLikeServer(items, sortBy: nil)) == ["b", "a"])
    }

    @Test func newestFirstByDateCreated() {
        func added(_ id: String, _ date: String) -> JfItem { var item = JfItem(id: id); item.dateCreated = date; return item }
        let items = [added("old", "2026-01-01T00:00:00Z"), added("new", "2026-09-01T00:00:00Z")]
        #expect(ids(sortedLikeServer(items, sortBy: "DateCreated", sortOrder: "Descending")) == ["new", "old"])
    }
}

@Suite("sortsLikeServer")
struct SortsLikeServerTests {
    @Test func theKeysSortedLikeServerKnowsCanBeSortedHere() {
        #expect(sortsLikeServer("SortName,AlbumArtist,Album"))
        #expect(sortsLikeServer("DateCreated"))
        #expect(sortsLikeServer("PlayCount"))
    }

    @Test func randomAndUnknownKeysGoBackToTheServer() {
        #expect(!sortsLikeServer("Random"))
        #expect(!sortsLikeServer("CommunityRating"))
        #expect(!sortsLikeServer(nil))
    }
}

@Suite("Song title order")
struct SongTitleOrderTests {
    // A song's SortName starts with its track number, so a Title sort must
    // read Name: by SortName, track 1 "Zoom" came before track 2 "Alpha".
    @Test func nameIgnoresTheTrackNumberInSortName() {
        var zoom = JfItem(id: "z", name: "Zoom")
        zoom.sortName = "0001 - Zoom"
        var alpha = JfItem(id: "a", name: "Alpha")
        alpha.sortName = "0002 - Alpha"
        #expect(sortedLikeServer([zoom, alpha], sortBy: "Name").map(\.id) == ["a", "z"])
        #expect(sortedLikeServer([alpha, zoom], sortBy: "SortName").map(\.id) == ["z", "a"])
        #expect(SongSortField.name.serverSortBy == "Name")
    }
}
