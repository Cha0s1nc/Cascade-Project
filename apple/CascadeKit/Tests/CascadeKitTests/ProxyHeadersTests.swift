import Foundation
import AVFoundation
import Testing
@testable import CascadeKit

struct ProxyHeadersTests {
    private func h(_ n: String, _ v: String) -> ProxyHeader { ProxyHeader(name: n, value: v) }

    @Test func namesMustBeTokens() {
        #expect(ProxyHeaders.nameProblem("CF-Access-Client-Id") == nil)
        #expect(ProxyHeaders.nameProblem("X_Custom.1~") == nil)
        for bad in ["", "Has Space", "colon:", "new\nline", "\u{FC}n\u{EF}", "(x)", "a/b"] {
            #expect(ProxyHeaders.nameProblem(bad) != nil, "\(bad) should be refused")
        }
    }

    @Test func authorizationHostAndContentLengthCannotBeOverridden() {
        for n in ["Authorization", "AUTHORIZATION", "host", "Host", "Content-Length", "X-Emby-Authorization", "Transfer-Encoding"] {
            #expect(ProxyHeaders.nameProblem(n)?.contains("cannot be overridden") == true, "\(n)")
        }
        #expect(ProxyHeaders.nameProblem("Authorization-Extra") == nil)
    }

    @Test func valuesArePresentBoundedAndClean() {
        #expect(ProxyHeaders.valueProblem("abc123") == nil)
        #expect(ProxyHeaders.valueProblem("a b\tc") == nil)
        #expect(ProxyHeaders.valueProblem("") != nil)
        #expect(ProxyHeaders.valueProblem("x\r\nInjected: 1") != nil)
        #expect(ProxyHeaders.valueProblem("x\u{0}y") != nil)
        #expect(ProxyHeaders.valueProblem(String(repeating: "x", count: 5000)) != nil)
    }

    @Test func parsesNameValueLines() {
        let r = ProxyHeaders.parse("CF-Access-Client-Id: abc.access\r\n\n# a note\nCF-Access-Client-Secret:  s3cret:with:colons  ")
        #expect(r.errors.isEmpty)
        #expect(r.headers == [h("CF-Access-Client-Id", "abc.access"), h("CF-Access-Client-Secret", "s3cret:with:colons")])
    }

    @Test func reportsEveryBadLineAndKeepsTheGoodOnes() {
        let r = ProxyHeaders.parse("Good: 1\nno colon here\nAuthorization: Bearer x\nBad Name: 1\nX-Empty:\ngood: 2")
        #expect(r.headers == [h("Good", "1")])
        #expect(r.errors.count == 5)
        #expect(r.errors[0].hasPrefix("Line 2:"))
        #expect(r.errors[1].hasPrefix("Line 3: Authorization cannot be overridden"))
        #expect(r.errors[4].hasPrefix("Line 6: good is already listed"))
    }

    @Test func capsTheList() {
        let text = (0..<(ProxyHeaders.maxCount + 3)).map { "X-H\($0): v" }.joined(separator: "\n")
        let r = ProxyHeaders.parse(text)
        #expect(r.headers.count == ProxyHeaders.maxCount)
        #expect(r.errors.count == 3)
    }

    @Test func formatRoundTripsThroughParse() {
        let list = [h("A", "1"), h("B-C", "x: y")]
        #expect(ProxyHeaders.parse(ProxyHeaders.format(list)).headers == list)
        #expect(ProxyHeaders.format([]) == "")
    }

    @Test func sanitizedDropsWhatIsNotTrustworthy() {
        let out = ProxyHeaders.sanitized([h("A", "1"), h("a", "2"), h("Host", "evil"), h("B", "x\ny"), h("", "x"), h("D", "ok")])
        #expect(out == [h("A", "1"), h("D", "ok")])
    }

    @Test func originNormalizesDefaultPortsAndWebSockets() {
        func o(_ s: String) -> String? { ProxyHeaders.origin(of: URL(string: s)!) }
        #expect(o("https://jf.example.com/web/index.html") == "https://jf.example.com")
        #expect(o("https://jf.example.com:443/x") == "https://jf.example.com")
        #expect(o("http://192.168.1.10:8096/x") == "http://192.168.1.10:8096")
        #expect(o("http://host:80") == "http://host")
        #expect(o("wss://jf.example.com/socket") == "https://jf.example.com")
        #expect(o("ws://h:8096/socket") == "http://h:8096")
        #expect(o("HTTPS://JF.Example.COM/") == "https://jf.example.com")
        #expect(o("file:///x") == nil)
        #expect(o("ftp://h/x") == nil)
    }

    @Test func headersOnlyReachTheServerOrigin() {
        let hs = [h("X-Token", "t")]
        let server = URL(string: "https://jf.example.com/jellyfin")!
        func f(_ s: String) -> [ProxyHeader] { ProxyHeaders.headers(for: URL(string: s)!, server: server, from: hs) }
        #expect(f("https://jf.example.com/Items/1/Images/Primary") == hs)
        #expect(f("wss://jf.example.com/socket") == hs)
        for other in ["https://lrclib.net/api/get", "https://jf.example.com.evil.net/", "https://other.example.com/",
                      "http://jf.example.com/", "https://jf.example.com:8443/", "https://jf.example.com@evil.net/"] {
            #expect(f(other).isEmpty, "\(other)")
        }
        #expect(ProxyHeaders.headers(for: server, server: nil, from: hs).isEmpty)
        #expect(ProxyHeaders.headers(for: server, server: server, from: []).isEmpty)
    }

    @Test func sameHostIgnoresSchemeAndPort() {
        func same(_ a: String, _ b: String) -> Bool { ProxyHeaders.sameHost(URL(string: a)!, URL(string: b)!) }
        #expect(same("http://jf.example.com/x", "https://jf.example.com/x"))
        #expect(same("https://JF.example.com:8443/", "https://jf.example.com/"))
        #expect(!same("https://jf.example.com/", "https://login.example.net/"))
    }

    // MARK: ProxyConnection

    @Test func theAPISessionCarriesTheHeadersAsDefaults() {
        let c = ProxyConnection()
        c.setServer("https://jf.example.com")
        c.setHeaders([h("CF-Access-Client-Id", "id"), h("Authorization", "refused")])
        let fields = c.session.configuration.httpAdditionalHeaders as? [String: String]
        #expect(fields == ["CF-Access-Client-Id": "id"])
    }

    @Test func aHeaderEditBuildsANewSessionAndNoHeadersMeansNone() {
        let c = ProxyConnection()
        c.setServer("https://jf.example.com")
        let first = c.session
        #expect(c.session === first, "reused until the headers change")
        c.setHeaders([h("X-A", "1")])
        #expect(c.session !== first)
        c.setHeaders([])
        #expect(c.session.configuration.httpAdditionalHeaders == nil)
    }

    @Test func onlyTheServerGetsTheProxySession() {
        let c = ProxyConnection()
        c.setServer("https://jf.example.com/jellyfin")
        c.setHeaders([h("X-A", "1")])
        #expect(c.session(for: URL(string: "https://jf.example.com/Items/1/Images/Primary")!) === c.session)
        #expect(c.session(for: URL(string: "https://lrclib.net/api/get")!) === URLSession.shared)
        #expect(c.session(for: URL(string: "https://evil.example.com/")!) === URLSession.shared)
    }

    @Test func everyAssetCarriesTheHeadersForTheServerOnly() {
        let c = ProxyConnection()
        c.setServer("https://jf.example.com")
        c.setHeaders([h("CF-Access-Client-Id", "id")])
        let mine = c.assetOptions(for: URL(string: "https://jf.example.com/Audio/1/stream")!,
                                  base: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        #expect(mine[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool == true, "the caller's own options survive")
        #expect(mine[ProxyConnection.assetHeaderFieldsKey] as? [String: String] == ["CF-Access-Client-Id": "id"])
        let other = c.assetOptions(for: URL(string: "https://cdn.example.net/x.mp3")!)
        #expect(other[ProxyConnection.assetHeaderFieldsKey] == nil)
    }

    @Test func headersForARequestFollowTheServer() {
        let c = ProxyConnection()
        c.setHeaders([h("X-A", "1")])
        #expect(c.headersToSend(for: URL(string: "https://jf.example.com/x")!).isEmpty, "no server set yet")
        c.setServer("https://jf.example.com")
        #expect(c.headersToSend(for: URL(string: "https://jf.example.com/x")!) == [h("X-A", "1")])
    }
}
