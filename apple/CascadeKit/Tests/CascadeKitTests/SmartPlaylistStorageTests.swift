import Foundation
import Testing
@testable import CascadeKit

// The stored shape is the desktop's (parseSmartPlaylists in
// src/core/smart-playlist.ts), so a settings import is a copy and either app
// reads what the other wrote.
struct SmartPlaylistStorageTests {
    /// What the desktop's store holds for one definition of every rule kind.
    private let desktop = """
    [{"id":"user:abc","name":"Mix","match":"any","rules":[
      {"field":"genre","op":"is","value":"Rock"},
      {"field":"genre","op":"isNot","value":"Jazz"},
      {"field":"artist","op":"is","value":"Aurora Vale"},
      {"field":"year","op":"between","min":1980,"max":1989},
      {"field":"addedWithinDays","op":"lte","days":14},
      {"field":"played","op":"is","value":false},
      {"field":"playCount","op":"gte","value":5},
      {"field":"favorite","op":"is","value":true}],
     "sortBy":"playCount","sortDir":"desc","limit":250}]
    """

    @Test func readsADefinitionTheDesktopWrote() throws {
        let list = SmartPlaylist.decodeList(Data(desktop.utf8))
        let p = try #require(list.first)
        #expect(p.id == "user:abc" && p.name == "Mix" && p.matchAny)
        #expect(p.sortBy == .playCount && p.descending && p.limit == 250)
        #expect(p.rules == [.genre("Rock", isNot: false), .genre("Jazz", isNot: true), .artist("Aurora Vale"),
                            .year(min: 1980, max: 1989), .addedWithinDays(14), .played(false),
                            .playCountAtLeast(5), .favorite(true)])
    }

    @Test func writesTheDesktopsShape() throws {
        let p = SmartPlaylist(id: "user:1", name: "N", matchAny: false, rules: [.year(min: 1990, max: 1999), .favorite(true)],
                              sortBy: .dateAdded, descending: false, limit: 50)
        let data = SmartPlaylist.encodeList([p])
        let list = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let o = try #require(list.first)
        #expect(o["match"] as? String == "all" && o["sortDir"] as? String == "asc")
        #expect(o["sortBy"] as? String == "dateAdded" && o["limit"] as? Int == 50)
        #expect(o["matchAny"] == nil && o["descending"] == nil)
        let rules = try #require(o["rules"] as? [[String: Any]])
        #expect(rules[0]["field"] as? String == "year" && rules[0]["op"] as? String == "between")
        #expect(rules[0]["min"] as? Int == 1990 && rules[0]["max"] as? Int == 1999)
        #expect(rules[1]["field"] as? String == "favorite" && rules[1]["value"] as? Bool == true)
    }

    @Test func roundTripsThroughTheStoredText() {
        let p = SmartPlaylist(id: "user:1", name: "N", matchAny: true,
                              rules: [.genre("Rock", isNot: true), .playCountAtLeast(2), .addedWithinDays(7)],
                              sortBy: .artist, descending: true, limit: 120)
        #expect(SmartPlaylist.decodeList(SmartPlaylist.encodeList([p])) == [p])
    }

    @Test func stillReadsTheShapeThisAppFirstWrote() throws {
        // matchAny / descending and Swift's own enum coding.
        let old = #"[{"id":"user:1","name":"Old","matchAny":true,"descending":true,"sortBy":"album","limit":30,"rules":[{"genre":{"_0":"Rock","isNot":false}},{"year":{"min":1990,"max":1999}},{"favorite":{"_0":true}}]}]"#
        let p = try #require(SmartPlaylist.decodeList(Data(old.utf8)).first)
        #expect(p.matchAny && p.descending && p.sortBy == .album && p.limit == 30)
        #expect(p.rules == [.genre("Rock", isNot: false), .year(min: 1990, max: 1999), .favorite(true)])
    }

    @Test func unknownRulesAreDroppedAndValidOnesKept() throws {
        let raw = """
        [{"id":"user:1","name":"Mix","rules":[
          {"field":"genre","op":"is","value":"Rock"},
          {"field":"genre","op":"contains","value":"Rock"},
          {"field":"telepathy","op":"is","value":true},
          {"field":"favorite","op":"is","value":"yes"}]}]
        """
        let p = try #require(SmartPlaylist.decodeList(Data(raw.utf8)).first)
        #expect(p.rules == [.genre("Rock", isNot: false)])
    }

    @Test func garbageFieldsFallBackToSafeDefaults() throws {
        let raw = #"[{"id":"user:1","name":"G","match":"xyz","sortBy":"xyz","sortDir":"xyz","limit":"a lot please","rules":[]}]"#
        let p = try #require(SmartPlaylist.decodeList(Data(raw.utf8)).first)
        #expect(!p.matchAny && p.sortBy == .name && !p.descending && p.limit == 100)
    }

    @Test func limitsAndYearsAreClampedAndOrdered() throws {
        let raw = """
        [{"id":"user:1","name":"Huge","limit":999999,"rules":[{"field":"year","op":"between","min":3000,"max":1}]},
         {"id":"user:2","name":"Negative","limit":-5,"rules":[]}]
        """
        let list = SmartPlaylist.decodeList(Data(raw.utf8))
        #expect(list[0].limit == 500 && list[1].limit == 1)
        #expect(list[0].rules == [.year(min: 1000, max: 2100)])
    }

    @Test func readsAJsonTextValueFromDefaultsAsWellAsData() throws {
        let defaults = try #require(UserDefaults(suiteName: "cascade.test.smart.\(UUID().uuidString)"))
        defaults.set(desktop, forKey: "k")
        #expect(SmartPlaylist.stored(in: defaults, key: "k").first?.name == "Mix")
        defaults.set(SmartPlaylist.encodeList([SmartPlaylist(id: "user:2", name: "Two")]), forKey: "k")
        #expect(SmartPlaylist.stored(in: defaults, key: "k").first?.name == "Two")
        #expect(SmartPlaylist.stored(in: defaults, key: "missing").isEmpty)
    }
}
