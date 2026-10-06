import Testing
import Foundation
@testable import CascadeKit

// Discord frames and activity, the control server's parse and routes, the token file.
struct IntegrationsTests {
    // MARK: Discord

    @Test func frameIsOpThenLengthLittleEndianThenJSON() {
        let d = DiscordFrame.handshake(clientId: "123")
        #expect(Array(d.prefix(8)) == [0, 0, 0, 0, UInt8(d.count - 8), 0, 0, 0])
        #expect(String(data: d.dropFirst(8), encoding: .utf8) == #"{"client_id":"123","v":1}"#)
    }

    @Test func decodeTakesWholeFramesAndKeepsAPartialOne() {
        var buf = DiscordFrame.encode(op: .ping, payload: Data("{}".utf8)) + DiscordFrame.encode(op: .frame, payload: Data(#"{"evt":"READY"}"#.utf8))
        let partial = DiscordFrame.encode(op: .frame, payload: Data("0123456789".utf8))
        buf.append(partial.prefix(12))
        let frames = DiscordFrame.decode(&buf)
        #expect(frames.map(\.op) == [3, 1])
        #expect(buf.count == 12)
        buf.append(partial.dropFirst(12))
        #expect(DiscordFrame.decode(&buf).count == 1 && buf.isEmpty)
    }

    func json(_ d: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: d.dropFirst(8)) as! [String: Any]
    }

    @Test func setActivityCarriesTypeStatusDisplayAndTimestamps() {
        let act = DiscordActivity(details: "Song", state: "Artist", watching: false, startMs: 1000, endMs: 5000,
                                  largeImage: "https://x/y.jpg", largeText: "Album")
        let m = json(DiscordFrame.setActivity(act, pid: 42, nonce: "n"))
        #expect(m["cmd"] as? String == "SET_ACTIVITY" && m["nonce"] as? String == "n")
        let args = m["args"] as! [String: Any], a = args["activity"] as! [String: Any]
        #expect(args["pid"] as? Int == 42)
        #expect(a["type"] as? Int == 2 && a["status_display_type"] as? Int == 1)
        #expect((a["timestamps"] as! [String: Int]) == ["start": 1000, "end": 5000])
        #expect((a["assets"] as! [String: String]) == ["large_image": "https://x/y.jpg", "large_text": "Album"])
    }

    @Test func watchingIsType3AndAnEmptyStateIsLeftOut() {
        let a = json(DiscordFrame.setActivity(DiscordActivity(details: "Movie", state: "", watching: true), pid: 1, nonce: "n"))["args"] as! [String: Any]
        let act = a["activity"] as! [String: Any]
        #expect(act["type"] as? Int == 3 && act["state"] == nil && act["assets"] == nil)
    }

    @Test func clearingSendsNoActivity() {
        let args = json(DiscordFrame.setActivity(nil, pid: 7, nonce: "n"))["args"] as! [String: Any]
        #expect(args["activity"] == nil && args["pid"] as? Int == 7)
    }

    @Test func longTextIsCutTo128() {
        let long = String(repeating: "a", count: 300)
        let act = json(DiscordFrame.setActivity(DiscordActivity(details: long, state: long, watching: false), pid: 1, nonce: "n"))
        let a = (act["args"] as! [String: Any])["activity"] as! [String: Any]
        #expect((a["details"] as! String).count == 128 && (a["state"] as! String).count == 128)
    }

    @Test func activityFromATrackUsesJellyfinRuntimeAndAlbum() {
        var item = JfItem(id: "t"); item.name = "Song"; item.albumArtist = "Band"; item.album = "LP"; item.runTimeTicks = 2_000_000_000
        let a = DiscordActivity.make(item: item, startMs: 10_000, fallbackDurationMs: 5)
        #expect(a.details == "Song" && a.state == "Band" && !a.watching)
        #expect(a.endMs == 10_000 + 200_000 && a.largeText == "LP")
    }

    @Test func activityFromAnEpisodeIsWatchingWithSeriesAndCode() {
        var item = JfItem(id: "e"); item.type = "Episode"; item.name = "Pilot"; item.seriesName = "Show"
        item.parentIndexNumber = 1; item.indexNumber = 2
        let a = DiscordActivity.make(item: item, startMs: 0, fallbackDurationMs: nil)
        #expect(a.watching && a.state == "Show \u{B7} S1:E2" && a.endMs == nil && a.largeText == nil)
    }

    @Test func backoffDoublesFrom15To60AndResets() {
        var b = RpcBackoff()
        #expect([b.next(), b.next(), b.next(), b.next()] == [15, 30, 60, 60])
        b.reset()
        #expect(b.next() == 15)
    }

    @Test func updatesAreHeldToOnePerFiveSeconds() {
        #expect(rpcSendWait(now: 100, lastSentAt: 98) == 3)
        #expect(rpcSendWait(now: 100, lastSentAt: 90) == 0)
    }

    // MARK: control server

    func req(_ method: String, _ path: String, token: String? = "t", body: String = "") -> ControlRequest {
        var h: [String: String] = [:]
        if let token { h["x-cascade-token"] = token }
        return ControlRequest(method: method, path: path, headers: h, body: Data(body.utf8))
    }
    final class Box: @unchecked Sendable { var actions: [String] = [] }

    func route(_ r: ControlRequest, session: ControlContext.Session? = nil, np: ControlNowPlaying = .empty, box: Box = Box()) -> ControlResponse {
        ControlServerProtocol.route(r, token: "t", context: ControlContext(version: "2.4.0", jellyfin: session, nowPlaying: np, perform: { box.actions.append($0) }))
    }

    @Test func parseWaitsForTheWholeBody() {
        let raw = "POST /cascade/control HTTP/1.1\r\nHost: x\r\nX-Cascade-Token: t\r\nContent-Length: 17\r\n\r\n"
        #expect(ControlServerProtocol.parse(Data(raw.utf8)) == .incomplete)
        #expect(ControlServerProtocol.parse(Data((raw + #"{"action":"next"}"#).utf8)) == .incomplete)
        guard case .request(let r) = ControlServerProtocol.parse(Data((raw + #"{"action":"next"}"#).utf8)) else {
            Issue.record("expected a request"); return
        }
        #expect(r.method == "POST" && r.path == "/cascade/control" && r.headers["x-cascade-token"] == "t")
        #expect(r.body.count == 17 || r.body.count == 16)
    }

    @Test func garbageIsMalformed() {
        #expect(ControlServerProtocol.parse(Data("nonsense\r\n\r\n".utf8)) == .malformed)
        #expect(ControlServerProtocol.parse(Data("GET / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .malformed)
    }

    @Test func aWrongOrMissingTokenIs401OnEveryRoute() {
        for path in ["/cascade/status", "/cascade/jellyfin", "/cascade/nope"] {
            #expect(route(req("GET", path, token: "wrong")).status == 401)
            #expect(route(req("GET", path, token: nil)).body == #"{"ok":false,"error":"Unauthorized"}"#)
        }
    }

    @Test func controlRunsOnlyTheThreeActions() {
        let box = Box()
        for a in ["playpause", "next", "prev"] { #expect(route(req("POST", "/cascade/control", body: #"{"action":"\#(a)"}"#), box: box).status == 200) }
        #expect(box.actions == ["playpause", "next", "prev"])
        for bad in [#"{"action":"stop"}"#, "not json", "{}"] {
            let res = route(req("POST", "/cascade/control", body: bad), box: box)
            #expect(res.status == 400 && res.body == #"{"ok":false,"error":"Bad request"}"#)
        }
        #expect(box.actions.count == 3)
    }

    @Test func statusJellyfinAndNowPlayingBodies() {
        #expect(route(req("GET", "/cascade/status")).body == #"{"ok":true,"app":"Cascade","version":"2.4.0"}"#)
        let nj = route(req("GET", "/cascade/jellyfin"))
        #expect(nj.status == 404 && nj.body == #"{"ok":false,"error":"Not connected to Jellyfin"}"#)
        let s = ControlContext.Session(url: "http://h:8096", token: "tok", userId: "u")
        #expect(route(req("GET", "/cascade/jellyfin"), session: s).body == #"{"ok":true,"url":"http:\/\/h:8096","token":"tok","userId":"u"}"#.replacingOccurrences(of: "\\/", with: "/"))
        #expect(route(req("GET", "/cascade/now-playing")).body == #"{"title":null,"artist":null,"isPlaying":false}"#)
        let np = ControlNowPlaying(title: "A \"B\"", artist: "C", album: "D", trackId: "t", artItemId: "a", artImageTag: "", durationMs: 1000, positionMs: 5, isPlaying: true)
        #expect(route(req("GET", "/cascade/now-playing"), np: np).body ==
                #"{"title":"A \"B\"","artist":"C","isPlaying":true,"album":"D","trackId":"t","artItemId":"a","artImageTag":"","durationMs":1000,"positionMs":5}"#)
    }

    @Test func wrongMethodOrPathIsAnEmpty404() {
        let r = route(req("GET", "/cascade/control"))
        #expect(r.status == 404 && r.body.isEmpty)
        #expect(route(req("POST", "/cascade/status")).status == 404)
        // Node's req.url includes the query string, so this is a different path there too.
        #expect(route(req("GET", "/cascade/status?x=1")).status == 404)
        let wire = String(data: r.data, encoding: .utf8)!
        #expect(wire.hasPrefix("HTTP/1.1 404 Not Found\r\n") && !wire.contains("Content-Type"))
    }

    @Test func tokenFileIsCreatedOnceAt0600AndNeverRewritten() throws {
        let dir = NSTemporaryDirectory() + "cascade-token-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/.cascade-control-token"
        let made = try #require(ControlToken.load(path: path))
        #expect(ControlToken.isValid(made))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(ControlToken.load(path: path) == made)
        // An existing file that is not a token is left alone, not regenerated.
        try "garbage".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(ControlToken.load(path: path) == nil)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "garbage")
    }
}
