import Testing
@testable import CascadeKit

// Ported from test/browse-mode.test.ts, and the video library cases of
// test/jellyfin.test.ts (splitVideoLibraryIds, effectiveLibraryIds, onePerSeries).
struct BrowseModeTests {
    typealias Mode = BrowseModeLogic

    @Test func sectionModeClassifiesMusicAndVideoViews() {
        for name in ["albums", "artists", "songs", "playlists", "genres", "history", "radio"] {
            #expect(Mode.sectionMode(name) == .music)
        }
        #expect(Mode.sectionMode("movies") == .video)
        #expect(Mode.sectionMode("shows") == .video)
    }

    @Test func sectionModeIsNilForViewsShownInEveryMode() {
        #expect(Mode.sectionMode("home") == nil)
        #expect(Mode.sectionMode("settings") == nil)
    }

    @Test func aDeepLinkOpensTheSectionOfItsType() {
        #expect(Mode.section(forItemType: "MusicAlbum") == "albums")
        #expect(Mode.section(forItemType: "Movie") == "movies")
        #expect(Mode.section(forItemType: "Episode") == "shows")
        #expect(Mode.section(forItemType: "Folder") == nil)
        #expect(Mode.sectionMode(Mode.section(forItemType: "Series")!) == .video)
    }

    @Test func resolvePrefersSavedVideoOnlyWithAVideoLibrary() {
        #expect(Mode.resolve(saved: nil, hasVideoLibrary: true) == .music)
        #expect(Mode.resolve(saved: "video", hasVideoLibrary: true) == .video)
        #expect(Mode.resolve(saved: "music", hasVideoLibrary: true) == .music)
        #expect(Mode.resolve(saved: "garbage", hasVideoLibrary: true) == .music)
        #expect(Mode.resolve(saved: "video", hasVideoLibrary: false) == .music)
        #expect(Mode.resolve(saved: nil, hasVideoLibrary: false) == .music)
    }
}

struct VideoLibrariesTests {
    private func lib(_ id: String, _ type: String) -> JfItem {
        var item = JfItem(id: id)
        item.collectionType = type
        return item
    }
    private func ep(_ id: String, _ series: String?) -> JfItem {
        var item = JfItem(id: id, type: "Episode")
        item.seriesId = series
        return item
    }
    private func movie(_ id: String) -> JfItem { JfItem(id: id, type: "Movie") }
    private func ids(_ items: [JfItem]) -> [String] { items.map(\.id) }

    @Test func splitSortsAMixedListByCollectionType() {
        let libs = [lib("m1", "movies"), lib("m2", "movies"), lib("t1", "tvshows")]
        let (movies, shows) = VideoLibraries.split(libs: libs, oldIds: ["m1", "t1", "m2"])
        #expect(movies == ["m1", "m2"])
        #expect(shows == ["t1"])
    }

    @Test func splitDropsAnIdNoLongerOnTheServer() {
        let (movies, shows) = VideoLibraries.split(libs: [lib("m1", "movies")], oldIds: ["m1", "gone"])
        #expect(movies == ["m1"])
        #expect(shows.isEmpty)
    }

    @Test func aSoleLibraryDefaultsOnWhenNothingWasEverChosen() {
        let libs = [lib("m1", "movies")]
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: nil) == ["m1"])
    }

    @Test func aSoleLibraryCanBeTurnedOffAndStayOff() {
        let libs = [lib("m1", "movies")]
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: []).isEmpty)
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: ["m1"]) == ["m1"])
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: ["something-else"]).isEmpty)
    }

    @Test func neverChosenWithARealChoiceSelectsNothing() {
        let libs = [lib("m1", "movies"), lib("m2", "movies")]
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: nil).isEmpty)
    }

    @Test func savedIdsWinButVanishedOnesAreDropped() {
        let libs = [lib("m1", "movies"), lib("m2", "movies"), lib("m3", "movies")]
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: ["m1", "m3"]) == ["m1", "m3"])
        #expect(VideoLibraries.effective(categoryLibs: libs, saved: ["m1", "gone"]) == ["m1"])
        #expect(VideoLibraries.effective(categoryLibs: [], saved: ["m1"]).isEmpty)
    }

    // The app's own rule on top of effective: never chosen browses everything.
    @Test func theAppShowsEveryLibraryOfAKindNeverChosen() {
        let libs = [lib("m1", "movies"), lib("m2", "movies")]
        #expect(VideoLibraries.selection(categoryLibs: libs, saved: nil) == ["m1", "m2"])
        #expect(VideoLibraries.selection(categoryLibs: libs, saved: []).isEmpty)
        #expect(VideoLibraries.selection(categoryLibs: libs, saved: ["m2"]) == ["m2"])
    }

    @Test func onePerSeriesKeepsTheFirstEpisodeOfEachSeries() {
        #expect(ids(VideoLibraries.onePerSeries([ep("e4", "s1"), ep("e3", "s1"), ep("e2", "s1"), ep("e1", "s1")])) == ["e4"])
        #expect(ids(VideoLibraries.onePerSeries([ep("a2", "A"), ep("b2", "B"), ep("a1", "A"), ep("b1", "B")])) == ["a2", "b2"])
    }

    @Test func onePerSeriesLeavesMoviesAlone() {
        let items = [movie("m1"), ep("e1", "s1"), movie("m2"), ep("e2", "s1")]
        #expect(ids(VideoLibraries.onePerSeries(items)) == ["m1", "e1", "m2"])
    }

    @Test func anEpisodeWithNoSeriesIsNeverDroppedOrMerged() {
        #expect(ids(VideoLibraries.onePerSeries([ep("e1", nil), ep("e2", nil), ep("e3", "s1")])) == ["e1", "e2", "e3"])
        #expect(ids(VideoLibraries.onePerSeries([ep("e1", ""), ep("e2", nil), ep("e3", "")])) == ["e1", "e2", "e3"])
    }

    @Test func aHalfWatchedEpisodeBeatsItsShowsNextUp() {
        // The caller lists partway-through first, then Next Up.
        let items = VideoLibraries.onePerSeries([ep("partway", "s1"), ep("next", "s1"), ep("other", "s2")])
        #expect(ids(items) == ["partway", "other"])
    }

    @Test func mergedLibrariesAreReorderedByRecentPlay() {
        func played(_ id: String, _ date: String) -> JfItem {
            var userData = JfUserData()
            userData.lastPlayedDate = date
            return JfItem(id: id, userData: userData)
        }
        let merged = [played("old", "2026-01-01T00:00:00Z"), played("new", "2026-09-01T00:00:00Z"), JfItem(id: "never")]
        #expect(ids(VideoLibraries.byRecentPlay(merged)) == ["new", "old", "never"])
    }

    @Test func collapsedLibrariesReadBackAndJunkIsNothingCollapsed() {
        #expect(CollapsedLibraries.decode(CollapsedLibraries.encode(["b", "a"])) == ["a", "b"])
        #expect(CollapsedLibraries.decode(nil).isEmpty)
        #expect(CollapsedLibraries.decode("not json").isEmpty)
        #expect(CollapsedLibraries.decode(#"{"a":1}"#).isEmpty)
        #expect(CollapsedLibraries.decode(#"["a", 3, null, "b"]"#) == ["a", "b"])
    }

    @Test func videoSortDefaultsToNewestFirstForDatesAndYears() {
        #expect(VideoSortField.added.defaultDirection == .descending)
        #expect(VideoSortField.year.defaultDirection == .descending)
        #expect(VideoSortField.name.defaultDirection == .ascending)
    }
}
