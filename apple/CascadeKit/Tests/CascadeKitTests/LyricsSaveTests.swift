import Testing
import Foundation
@testable import CascadeKit

/// Answers every request with a fixed status and records the last one, so the save's request
/// shape can be checked without a plugin (the test server has none).
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 204
    nonisolated(unsafe) static var last: URLRequest?
    nonisolated(unsafe) static var body: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.last = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            Self.body = data
        } else { Self.body = request.httpBody }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("nope".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct LyricsSaveTests {
    private func setup(status: Int) -> (JellyfinClient, URLSession) {
        StubProtocol.status = status
        StubProtocol.last = nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        let client = JellyfinClient(config: ServerConfig(url: "http://jf.test", token: "tok", userId: "u", libraryIds: [], deviceId: "dev"))
        return (client, URLSession(configuration: cfg))
    }

    @Test func postsTheLrcToThePluginRoute() async throws {
        let (client, session) = setup(status: 204)
        try await client.saveLyrics(itemId: "abc", api: .server, lrc: "[00:01.00]hi", session: session)
        let req = try #require(StubProtocol.last)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://jf.test/CascadeServer/Lyrics/abc")
        #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"tok\"") == true)
        let json = try JSONSerialization.jsonObject(with: try #require(StubProtocol.body)) as? [String: String]
        #expect(json == ["lrc": "[00:01.00]hi"])
    }

    @Test func legacyPluginUsesTheOldRoute() async throws {
        let (client, session) = setup(status: 200)
        try await client.saveLyrics(itemId: "abc", api: .legacy, lrc: "x", session: session)
        #expect(StubProtocol.last?.url?.path == "/Audio/abc/CascadeLyrics")
    }

    @Test func aRefusedSaveThrowsWithItsStatus() async {
        let (client, session) = setup(status: 403)
        do {
            try await client.saveLyrics(itemId: "abc", api: .server, lrc: "x", session: session)
            Issue.record("a 403 must not read as saved")
        } catch let e as JellyfinError { #expect(e.status == 403) }
        catch { Issue.record("wrong error \(error)") }
    }
}
