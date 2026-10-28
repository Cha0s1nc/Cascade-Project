import Foundation
import Testing
@testable import CascadeKit

// The desktop's test/announcements.test.ts cases.
struct AnnouncementsTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
    static var base: [String: Any] { ["id": "a", "date": "2026-11-01", "title": "Hello"] }
    static func with(_ extra: [String: Any]) -> [String: Any] { base.merging(extra) { $1 } }
    static func parse(_ raw: Any?, _ version: String = "2.3.0") -> [Announcement] {
        Announcements.parse(raw, platform: "ios", version: version, now: now)
    }

    @Test func aWellFormedEntryComesThroughAsText() {
        #expect(Self.parse([Self.with(["body": " Hi\u{07} ", "link": "https://example.com/x", "extra": 1])])
                == [Announcement(id: "a", date: "2026-11-01", title: "Hello", body: "Hi", link: URL(string: "https://example.com/x"), kind: .official, source: nil)])
        #expect(Self.parse([Self.base]).first?.body == "")
    }

    @Test func brokenEntriesAreDroppedOneAtATime() {
        let list = Self.parse([NSNull(), 7, Self.with(["id": ""]), Self.with(["title": 3]), Self.with(["date": "soon"]),
                               Self.with(["id": "ok"]), Self.with(["id": "ok", "title": "dupe"])])
        #expect(list.map(\.id) == ["ok"])
        #expect(list.first?.title == "Hello")
        #expect(Self.parse(["not": "a list"]).isEmpty)
    }

    @Test func onlyHttpsLinksAreKept() {
        for link: Any in ["http://example.com", "javascript:alert(1)", "file:///etc/passwd", "https://a b", 42] {
            #expect(Self.parse([Self.with(["link": link])]).first?.link == nil)
        }
    }

    @Test func platformsVersionsAndExpiryFilter() {
        func n(_ e: [String: Any], _ v: String = "2.3.0") -> Int { Self.parse([Self.with(e)], v).count }
        #expect(n(["platforms": ["desktop", "tvos"]]) == 0)
        #expect(n(["platforms": ["ios"]]) == 1)
        #expect(n(["minVersion": "2.3.0", "maxVersion": "2.3.0"]) == 1)
        #expect(n(["minVersion": "2.3.1"]) == 0)
        #expect(n(["maxVersion": "2.2.9"]) == 0)
        #expect(n(["maxVersion": "2.3.0"], "2.3.0-b2") == 1)
        #expect(n(["expires": "2026-11-10"]) == 1)
        #expect(n(["expires": "2026-11-09"]) == 0)
    }

    @Test func newestFirstAndTheInbox() {
        let list = Self.parse([Self.with(["id": "old", "date": "2026-01-01"]), Self.with(["id": "new", "date": "2026-10-01"]), Self.with(["id": "c"])])
        #expect(list.map(\.id) == ["c", "new", "old"])
        let inbox = Announcements.inbox(list, dismissed: ["new"], seen: ["c"])
        #expect(inbox.items.map(\.id) == ["c", "old"])
        #expect(inbox.unseen == 1)
    }

    @Test func aServersPostsKeepTheirIdsApartAndCarryItsName() {
        let raw: [String: Any] = ["server": ["id": "abc", "name": "Chaos"], "items": [Self.with(["source": "Cascade", "kind": "official"])]]
        let list = Announcements.parseServer(raw, platform: "ios", version: "2.3.0", now: Self.now)
        #expect(list == [Announcement(id: "server:abc:a", date: "2026-11-01", title: "Hello", body: "", link: nil, kind: .server, source: "Chaos")])
        #expect(Announcements.parseServer(["server": ["id": "abc"], "items": [Self.base]], platform: "ios", version: "2.3.0", now: Self.now).first?.source == "Your server")
        #expect(Announcements.parseServer(["items": [Self.base]], platform: "ios", version: "2.3.0", now: Self.now).isEmpty)
        #expect(Announcements.parseServer(nil).isEmpty)
    }

    @Test func aDashboardMessageIsKeptAsAServerEntry() {
        let msg = ServerMessage(header: "Maintenance", text: "Restarting at 2", timeout: nil)
        var stored = Announcements.addMessage(nil, msg, serverName: "Chaos", now: Self.now)
        stored = Announcements.addMessage(stored, ServerMessage(header: "Back", text: "", timeout: nil), serverName: "", now: Self.now + 1)
        let list = Announcements.parse(stored, platform: "ios", version: "2.3.0", now: Self.now, kind: .server)
        #expect(list.map { [$0.title, $0.kind.rawValue, $0.source ?? ""] } == [["Back", "server", "Your server"], ["Maintenance", "server", "Chaos"]])
        #expect(list[0].id.hasPrefix("message:") && list[0].id != list[1].id)
        for i in 0..<60 { stored = Announcements.addMessage(stored, msg, serverName: "Chaos", now: Self.now + Double(i * 2)) }
        #expect(stored.count == 50)
    }
}
