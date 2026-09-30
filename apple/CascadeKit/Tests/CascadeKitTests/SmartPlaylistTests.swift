import Foundation
import Testing
@testable import CascadeKit

// The desktop's smart playlist rules, ported (test/smart-playlist.test.ts).
struct SmartPlaylistTests {
    private func song(_ name: String, genres: [String] = [], artist: String? = nil, year: Int? = nil,
                      added: String? = nil, plays: Int? = nil, played: Bool? = nil, favorite: Bool? = nil) -> JfItem {
        var item = JfItem(id: name, name: name, type: "Audio",
                          userData: JfUserData(played: played, isFavorite: favorite, playCount: plays))
        item.genres = genres
        item.albumArtist = artist
        item.productionYear = year
        item.dateCreated = added
        return item
    }
    private let now = PlayHistory.date("2026-09-29T12:00:00Z")!

    @Test func twoGenreRulesStayAnAnd() {
        let p = SmartPlaylist(name: "x", rules: [.genre("Rock", isNot: false), .genre("Jazz", isNot: false)])
        // Only the first is pushed: Jellyfin ORs one parameter's values.
        #expect(p.query["genres"] == "Rock")
        let both = song("both", genres: ["rock", "Jazz"]), rockOnly = song("rock", genres: ["Rock"])
        #expect(p.apply([both, rockOnly], now: now).map(\.id) == ["both"])
    }

    @Test func anyMatchPushesNothingAndMatchesEither() {
        let p = SmartPlaylist(name: "x", matchAny: true, rules: [.favorite(true), .playCountAtLeast(5)])
        #expect(p.query.isEmpty)
        let items = [song("fav", favorite: true), song("played", plays: 7), song("neither", plays: 1)]
        #expect(p.apply(items, now: now).map(\.id) == ["fav", "played"])
    }

    @Test func eachRuleChecks() {
        #expect(SmartPlaylist.ruleMatches(.genre("Rock", isNot: true), song("a", genres: ["Jazz"]), now: now))
        #expect(SmartPlaylist.ruleMatches(.artist("coldplay"), song("a", artist: "Coldplay"), now: now))
        #expect(SmartPlaylist.ruleMatches(.year(min: 1990, max: 1999), song("a", year: 1994), now: now))
        #expect(!SmartPlaylist.ruleMatches(.year(min: 1990, max: 1999), song("a"), now: now))
        #expect(SmartPlaylist.ruleMatches(.addedWithinDays(7), song("a", added: "2026-09-25T00:00:00.0000000Z"), now: now))
        #expect(!SmartPlaylist.ruleMatches(.addedWithinDays(7), song("a", added: "2026-09-01T00:00:00Z"), now: now))
        #expect(SmartPlaylist.ruleMatches(.played(false), song("a"), now: now))
    }

    @Test func noRulesIsEverythingSortedAndCapped() {
        let p = SmartPlaylist(name: "x", sortBy: .playCount, descending: true, limit: 2)
        let items = [song("one", plays: 1), song("three", plays: 3), song("two", plays: 2)]
        #expect(p.apply(items, now: now).map(\.id) == ["three", "two"])
    }

    @Test func storedJunkIsDroppedAndValuesClamped() {
        let good = SmartPlaylist(id: "user:1", name: "  Mix  ", rules: [.year(min: 2100, max: 3000), .artist("  "),
                                                                      .addedWithinDays(99999)], limit: 9999)
        let data = SmartPlaylist.encodeList([good, SmartPlaylist(id: "user:2", name: "   ")])
        let back = SmartPlaylist.decodeList(data)
        #expect(back.count == 1)
        #expect(back[0].name == "Mix")
        #expect(back[0].limit == SmartPlaylist.maxLimit)
        #expect(back[0].rules == [.year(min: 2100, max: 2100), .addedWithinDays(3650)])
        #expect(SmartPlaylist.decodeList(Data("not json".utf8)).isEmpty)
        #expect(SmartPlaylist.decodeList(nil).isEmpty)
    }

    @Test func wideYearRangesAreLeftToTheClient() {
        #expect(SmartPlaylist(name: "x", rules: [.year(min: 1000, max: 2100)]).query["years"] == nil)
        #expect(SmartPlaylist(name: "x", rules: [.year(min: 1990, max: 1992)]).query["years"] == "1990,1991,1992")
    }

    @Test func byNameIsByTitleNotTrackNumberedSortName() {
        var a = song("Overdrive Track 2"); a.sortName = "0002 - Overdrive Track 2"
        var b = song("Unplugged Track 1"); b.sortName = "0001 - Unplugged Track 1"
        var c = song("Overdrive Track 10"); c.sortName = "0010 - Overdrive Track 10"
        #expect(SmartPlaylist(name: "x").apply([b, c, a], now: now).map(\.id)
                == ["Overdrive Track 2", "Overdrive Track 10", "Unplugged Track 1"])
    }
}
