import Foundation
import Testing
@testable import CascadeKit

// Offline Mode's rules (the same cases as the desktop's
// test/offline-mode.test.ts) and the swap inside JellyfinClient.send: with a
// catalog set, a GET is answered from it and nothing reaches the network.

struct OfflineModeTests {
    @Test func theManualSwitchOutranksTheNetwork() {
        var s = OfflineState.online
        s = OfflineMode.next(s, .setSwitch(true))
        #expect(s == .manual)
        #expect(OfflineMode.next(s, .reachable) == .manual)
        #expect(OfflineMode.next(s, .unreachable) == .manual)
        #expect(OfflineMode.next(s, .setSwitch(false)) == .online)
    }

    @Test func aDropTurnsItOnByItselfAndAnAnswerTurnsItOff() {
        var s = OfflineState.online
        s = OfflineMode.next(s, .unreachable)
        #expect(s == .unreachable)
        #expect(OfflineMode.next(s, .unreachable) == .unreachable)
        #expect(OfflineMode.next(s, .reachable) == .online)
        #expect(OfflineMode.next(s, .setSwitch(true)) == .manual)
        // Turning off a switch that was not on changes nothing.
        #expect(OfflineMode.next(s, .setSwitch(false)) == .unreachable)
    }

    @Test func onlyOnlineIsOnline() {
        #expect(!OfflineMode.isOffline(.online))
        #expect(OfflineMode.isOffline(.manual))
        #expect(OfflineMode.isOffline(.unreachable))
    }

    @Test func probesBackOffFrom30SecondsToFiveMinutes() {
        #expect([0, 1, 2, 3, 4, 5, 50].map { OfflineMode.probeDelay(attempt: $0) } == [30, 60, 120, 240, 300, 300, 300])
        #expect(OfflineMode.probeDelay(attempt: -1) == 30)
    }

    @Test func anExpiredSessionIsNeverOfflineMode() {
        #expect(OfflineMode.failureKind(status: nil) == .unreachable)
        #expect(OfflineMode.failureKind(status: 0) == .unreachable)
        for s in [502, 503, 504] { #expect(OfflineMode.failureKind(status: s) == .unreachable) }
        #expect(OfflineMode.failureKind(status: 401) == .auth)
        #expect(OfflineMode.failureKind(status: 403) == .auth)
        for s in [400, 404, 500] { #expect(OfflineMode.failureKind(status: s) == .error) }
        #expect(OfflineMode.isNoAnswer(URLError(.cannotConnectToHost)))
        #expect(OfflineMode.isNoAnswer(URLError(.timedOut)))
        #expect(!OfflineMode.isNoAnswer(URLError(.cancelled)), "a cancelled request says nothing about the server")
        #expect(!OfflineMode.isNoAnswer(OfflineError()))
    }

    @Test func updatesWaitUntilOnline() {
        #expect(OfflineMode.checksUpdates(.online))
        #expect(!OfflineMode.checksUpdates(.manual))
        #expect(OfflineMode.updateCheckDue(from: .unreachable, to: .online))
        #expect(OfflineMode.updateCheckDue(from: .manual, to: .online))
        #expect(!OfflineMode.updateCheckDue(from: .online, to: .online))
        #expect(!OfflineMode.updateCheckDue(from: .online, to: .manual))
    }

    @Test func aGetIsAnsweredFromTheCatalogBehindAProxyPath() throws {
        let engine = OfflineQuery.Engine(try OfflineQueryTests.catalog())
        let url = URL(string: "https://example.test/jellyfin/Items/alb1")!
        let data = try OfflineMode.answer(URLRequest(url: url), base: "https://example.test/jellyfin", engine: engine)
        let item = try JSON.decoder.decode(JfItem.self, from: data)
        #expect(item.id == "alb1")

        var list = URLComponents(string: "https://example.test/Items")!
        list.queryItems = [.init(name: "ParentId", value: "alb1"), .init(name: "SortBy", value: "IndexNumber")]
        let page = try JSON.decoder.decode(JfItemsResponse.self,
                                           from: try OfflineMode.answer(URLRequest(url: list.url!), base: "https://example.test/",
                                                                        engine: engine))
        #expect(page.items?.map(\.id) == ["trk1", "trk2"])
    }

    @Test func anythingButAGetIsRefusedAndAMissingIdIsA404() throws {
        let engine = OfflineQuery.Engine(try OfflineQueryTests.catalog())
        var post = URLRequest(url: URL(string: "https://example.test/UserFavoriteItems/trk1")!)
        post.httpMethod = "POST"
        #expect(throws: OfflineError.self) { try OfflineMode.answer(post, base: "https://example.test", engine: engine) }
        do {
            _ = try OfflineMode.answer(URLRequest(url: URL(string: "https://example.test/Items/nothere")!),
                                       base: "https://example.test", engine: engine)
            Issue.record("a missing id answered")
        } catch let e as JellyfinError {
            #expect(e.status == 404)
        }
    }

    @Test func theGateFollowsTheState() {
        let gate = OfflineGate()
        #expect(!gate.isOffline)
        gate.set(.unreachable)
        #expect(gate.isOffline)
        #expect(throws: OfflineError.self) { try gate.check() }
        gate.set(.online)
        #expect(throws: Never.self) { try gate.check() }
    }

    @Test func savedLyricsKeepTheirCredit() throws {
        var index = try OfflineQueryTests.catalog()
        let credit = SpicyCredit(provider: "Spicy Lyrics",
                                 uploader: SpicyContributor(name: "ana", url: URL(string: "https://example.test/ana")),
                                 maker: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        index.setLyrics("trk1", source: "spicy", synced: true,
                        lines: [LyricLine(start: 10_000_000, text: "la", words: nil)], now: now, credit: credit)
        let back = OfflineIndex.decode(index.encoded())
        let saved = try #require(back.lyrics(of: "trk1", now: now))
        #expect(saved.credit == credit)
        #expect(saved.sourceLabel == "Spicy Lyrics")
        #expect(back.lyrics(of: "trk1", now: now.addingTimeInterval(26 * 86_400)) == nil, "SpicyLyrics expire after 25 days")
    }

    @Test func sourceKeysMatchTheDesktop() {
        typealias L = OfflineIndex.StoredLyrics
        #expect(L.sourceKey(label: "Spotify via Spicy Lyrics", hasCredit: true) == "spicy")
        #expect(L.sourceKey(label: "Kugou", hasCredit: false) == "kugou")
        #expect(L.sourceKey(label: "LRCLIB", hasCredit: false) == "lrclib")
        #expect(L.sourceKey(label: "Jellyfin", hasCredit: false) == "jellyfin")
        #expect(L.sourceKey(label: "Cascade (karaoke)", hasCredit: false) == "cascade")
    }
}

// MARK: - The client

/// Counts every request and answers with a set status, or fails as if
/// nothing answered. Its own type, so it does not share counts with other
/// suites' stubs.
private final class CountingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var status: Int? = 200
    nonisolated(unsafe) static var body = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        guard let status = Self.status else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// What onFailure was told, in order.
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int?] = []
    func add(_ s: Int?) { lock.lock(); seen.append(s); lock.unlock() }
    var all: [Int?] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite(.serialized) struct OfflineClientTests {
    private func client(libraries: [String] = []) -> JellyfinClient {
        CountingProtocol.requests = 0
        CountingProtocol.status = 200
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CountingProtocol.self]
        return JellyfinClient(config: ServerConfig(url: "http://jf.test", token: "tok", userId: "user1",
                                                   libraryIds: libraries, deviceId: "dev"),
                              session: URLSession(configuration: cfg))
    }

    @Test func offlineNothingReachesTheNetwork() async throws {
        let client = client()
        await client.setOfflineCatalog(try OfflineQueryTests.catalog())
        #expect(await client.isOffline)

        let page: JfItemsResponse = try await client.get("/Items", params: ["parentId": "alb1", "sortBy": "IndexNumber"])
        #expect(page.items?.map(\.id) == ["trk1", "trk2"])
        let raw = try await client.getData("/Items/trk1")
        #expect(try JSON.decoder.decode(JfItem.self, from: raw).name == "Intro")

        await #expect(throws: OfflineError.self) {
            try await client.postRaw("/UserFavoriteItems/trk1", body: Optional<EmptyBody>.none)
        }
        await #expect(throws: OfflineError.self) { try await client.delete("/Items/trk1") }
        #expect(await client.imageUrl(itemId: "alb1") == nil, "no cover is asked of the server offline")
        #expect(await client.artUrl(itemId: "alb1", tag: "t") == nil)
        #expect(CountingProtocol.requests == 0)
    }

    @Test func backOnlineRequestsGoOutAgain() async throws {
        let client = client()
        await client.setOfflineCatalog(try OfflineQueryTests.catalog())
        await client.setOfflineCatalog(nil)
        #expect(await !client.isOffline)
        _ = try await client.getData("/System/Ping")
        #expect(CountingProtocol.requests == 1)
        #expect(await client.imageUrl(itemId: "alb1") != nil)
    }

    @Test func theProbeGoesOutEvenOffline() async throws {
        let client = client()
        await client.setOfflineCatalog(try OfflineQueryTests.catalog())
        #expect(await client.serverAnswers())
        CountingProtocol.status = nil
        #expect(await !client.serverAnswers())
        CountingProtocol.status = 503
        #expect(await !client.serverAnswers())
        #expect(CountingProtocol.requests == 3)
    }

    @Test func aClientCanStartOffline() async throws {
        CountingProtocol.requests = 0
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CountingProtocol.self]
        let client = JellyfinClient(config: ServerConfig(url: "http://jf.test", token: "tok", userId: "user1", deviceId: "dev"),
                                    session: URLSession(configuration: cfg), offlineCatalog: try OfflineQueryTests.catalog())
        #expect(await client.isOffline)
        _ = try await client.getData("/UserViews")
        #expect(CountingProtocol.requests == 0)
    }

    @Test func failuresAreReportedForDropDetection() async throws {
        let client = client()
        let log = FailureLog()
        await client.onFailure { log.add($0) }
        CountingProtocol.status = 503
        _ = try? await client.getData("/Items")
        CountingProtocol.status = nil
        _ = try? await client.getData("/Items")
        CountingProtocol.status = 200
        _ = try? await client.getData("/Items")
        #expect(log.all == [503, nil])
    }

    @Test func offlineTheLibraryScopeTakesInThePlaceholders() async throws {
        let client = client(libraries: ["libmusic"])
        #expect(await client.libraryScope == ["libmusic"])
        await client.setOfflineCatalog(try OfflineQueryTests.catalog())
        #expect(await client.libraryScope == ["libmusic", "cascade-offline-music", "cascade-offline-movies", "cascade-offline-shows"])
        // Nothing picked means everything, offline too.
        let all = self.client()
        await all.setOfflineCatalog(try OfflineQueryTests.catalog())
        #expect(await all.libraryScope == [])
    }
}
