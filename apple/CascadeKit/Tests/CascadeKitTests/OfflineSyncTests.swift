import Foundation
import Testing
@testable import CascadeKit

// Syncing what happened offline: coalescing, the conflict rule and the play
// history catch-up (OfflineSync), against the fixture shared with the
// desktop's test/offline-sync.test.ts, plus the catalog's side of it.
struct OfflineSyncTests {
    struct PlayRow: Decodable {
        var itemId: String
        var userId: String
        var date: String
        var play: OfflineIndex.Play {
            .init(itemId: itemId, userId: userId, date: Date(timeIntervalSince1970: (OfflineQuery.time(date) ?? 0) / 1000))
        }
    }
    struct Snapshot: Decodable { var entries: [OfflineIndex.HistoryEntry] }
    struct CoalesceCase: Decodable { var name: String; var changes: [OfflineIndex.UserDataChange]; var expected: [OfflineSync.PendingUpdate] }
    struct DecideCase: Decodable { var name: String; var update: OfflineSync.PendingUpdate; var server: JfItem?; var expected: OfflineSync.Send? }
    struct CatchUpCase: Decodable {
        var name: String; var history: Snapshot?; var playsHeld: Bool; var plays: [PlayRow]; var server: [JfItem]; var expected: String
    }
    struct ReplayOrder: Decodable { var plays: [PlayRow]; var expected: [String] }
    struct Fixture: Decodable {
        var coalesce: [CoalesceCase]; var decide: [DecideCase]; var catchUp: [CatchUpCase]; var replayOrder: ReplayOrder
    }

    static func fixture() throws -> Fixture {
        try JSON.decoder.decode(Fixture.self, from: Data(contentsOf: OfflineVideoTests.repo.appending(path: "shared/fixtures/offline-sync.json")))
    }

    @Test func coalescingMatchesTheDesktopFixture() throws {
        let cases = try Self.fixture().coalesce
        #expect(cases.count >= 8)
        for c in cases { #expect(OfflineSync.coalesce(c.changes) == c.expected, "\(c.name)") }
    }

    @Test func theConflictRuleMatchesTheDesktopFixture() throws {
        let cases = try Self.fixture().decide
        #expect(cases.count >= 7)
        for c in cases { #expect(OfflineSync.toSend(c.update, server: c.server) == c.expected, "\(c.name)") }
    }

    @Test func theCatchUpMatchesTheDesktopFixture() throws {
        let cases = try Self.fixture().catchUp
        #expect(cases.count >= 7)
        for c in cases {
            let history = c.history.map { OfflineIndex.History(takenAt: Date(), entries: $0.entries) }
            let result = OfflineSync.catchUp(plays: c.plays.map(\.play), history: history, held: c.playsHeld, server: c.server)
            #expect(result.rawValue == c.expected, "\(c.name)")
        }
    }

    @Test func playsReplayOldestFirst() throws {
        let o = try Self.fixture().replayOrder
        #expect(OfflineSync.oldestFirst(o.plays.map(\.play)).map(\.itemId) == o.expected)
    }

    @Test func theUserDataBodyIsPascalCaseWithNothingUnset() throws {
        let body = String(decoding: try JSON.encoder.encode(OfflineSync.UserDataBody(playbackPositionTicks: 5, played: nil, lastPlayedDate: "2026-10-16T10:00:00.000Z")), as: UTF8.self)
        #expect(body.contains("\"PlaybackPositionTicks\":5") && body.contains("\"LastPlayedDate\""))
        #expect(!body.contains("Played\""))
    }

    static func episode(_ id: String, _ ud: JfUserData = JfUserData()) -> JfItem {
        var item = JfItem(id: id, name: id, type: "Episode", runTimeTicks: 1000)
        item.userData = ud
        return item
    }

    @Test func aQueuedChangeShowsAtOnceAndOverARefreshUntilSent() {
        var index = OfflineIndex()
        index.add(Self.episode("e1"), tracks: [Self.episode("e1", JfUserData(playbackPositionTicks: 0, played: false))])
        index.addChange(.init(itemId: "e1", userId: "u1", at: "2026-10-16T10:00:00.000Z", kind: .position, ticks: 500))
        #expect(index.tracks["e1"]?.item.userData?.playbackPositionTicks == 500)
        #expect(index.collections[0].item.userData?.playbackPositionTicks == 500)
        index.refreshUserData([Self.episode("e1", JfUserData(playbackPositionTicks: 0, played: false, isFavorite: true))])
        #expect(index.tracks["e1"]?.item.userData?.playbackPositionTicks == 500)
        #expect(index.tracks["e1"]?.item.userData?.isFavorite == true)
        index.changes = []
        index.refreshUserData([Self.episode("e1", JfUserData(playbackPositionTicks: 0))])
        #expect(index.tracks["e1"]?.item.userData?.playbackPositionTicks == 0)
        #expect(index.userDataIds == ["e1"])
        // Junk never reaches the queue.
        index.addChange(.init(itemId: "../x", userId: "u1", at: "2026-10-16T10:00:00Z", kind: .position, ticks: 1))
        index.addChange(.init(itemId: "e1", userId: "u1", at: "never", kind: .position, ticks: 1))
        #expect(index.changes.isEmpty)
    }

    @Test func offlinePlaysSitOnTopOfTheSnapshot() {
        var index = OfflineIndex()
        let song = { (id: String) in JfItem(id: id, name: id, type: "Audio") }
        index.add(JfItem(id: "al", name: "al", type: "MusicAlbum"), tracks: [song("s1"), song("s2")])
        var row = JfItem(id: "s1")
        var ud = JfUserData(playCount: 4)
        ud.lastPlayedDate = "2026-10-15T20:00:00.0000000Z"
        row.userData = ud
        index.setHistory([row], takenAt: Date())
        #expect(index.tracks["s1"]?.item.userData?.playCount == 4)
        #expect(index.tracks["s1"]?.item.userData?.played == true)
        index.addPlay(.init(itemId: "s1", userId: "u1", date: Date(timeIntervalSince1970: 1_792_144_800)))
        #expect(index.tracks["s1"]?.item.userData?.playCount == 5)
        #expect(index.tracks["s1"]?.item.userData?.lastPlayedDate?.hasPrefix("2026-10-16") == true)
        index.setHistory([row], takenAt: Date())
        #expect(index.tracks["s1"]?.item.userData?.playCount == 5, "a queued play stays counted")
    }

    @Test func queuedChangesAndTheHeldFlagSurviveASave() {
        var index = OfflineIndex()
        index.add(Self.episode("e1"), tracks: [Self.episode("e1")])
        index.addPlay(.init(itemId: "e1", userId: "u1", date: Date()))
        index.addChange(.init(itemId: "e1", userId: "u1", at: "2026-10-16T10:00:00.000Z", kind: .favorite, favorite: true, was: false))
        index.playsHeld = true
        let back = OfflineIndex.decode(index.encoded())
        #expect(back.changes == index.changes)
        #expect(back.playsHeld)
        var none = index
        none.plays = []
        #expect(!OfflineIndex.decode(none.encoded()).playsHeld, "nothing to hold")
        #expect(OfflineIndex.decode(Data("{\"tracks\":{}}".utf8)).changes.isEmpty, "an older file has none")
    }

    @Test func theStorageLimit() {
        #expect(OfflineIndex.overStorageLimit(used: 9, adding: 2, limit: 10))
        #expect(!OfflineIndex.overStorageLimit(used: 8, adding: 2, limit: 10))
        #expect(!OfflineIndex.overStorageLimit(used: 1 << 40, adding: 1 << 40, limit: nil))
    }
}
