import Foundation
import Testing
@testable import CascadeKit

// The offline query engine against test/fixtures/offline-query.json at the
// repo root, the same cases the desktop's test/offline-query.test.ts runs, so
// the two engines answer alike.
struct OfflineQueryTests {
    /// One request param, as the fixture writes it.
    enum Scalar: Decodable, Sendable {
        case string(String), bool(Bool), int(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int.self) { self = .int(i) }
            else { self = .string(try c.decode(String.self)) }
        }
        var text: String {
            switch self {
            case .string(let s): return s
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            }
        }
    }

    struct Case: Decodable, Sendable {
        var name: String
        var path: String
        var params: [String: Scalar]
        var status: Int?
        var ids: [String]?
        var total: Int?
        var unknownRoute: Bool?
    }

    struct Fixture: Decodable { var cases: [Case] }

    static let fixtureURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "test/fixtures/offline-query.json")

    static let data: Data = (try? Data(contentsOf: fixtureURL)) ?? Data()
    /// The raw JSON, for each case's partial `body`.
    static func raw() -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    /// The fixture's catalog is in the desktop's key case, which JSON.decoder
    /// reads; decode() reads the Apple app's own file instead.
    static func catalog() throws -> OfflineIndex {
        let json = try JSONSerialization.data(withJSONObject: raw()["catalog"] ?? [:])
        return try JSON.decoder.decode(OfflineIndex.self, from: json).validated()
    }

    /// Every key of `expected` matches in `actual`; arrays match element by
    /// element and must be the same length.
    static func partial(_ actual: Any?, _ expected: Any?, _ at: String) -> String? {
        if let e = expected as? [Any] {
            guard let a = actual as? [Any] else { return "\(at) is not an array" }
            guard a.count == e.count else { return "\(at) has \(a.count), wanted \(e.count)" }
            for i in e.indices { if let bad = partial(a[i], e[i], "\(at)[\(i)]") { return bad } }
            return nil
        }
        if let e = expected as? [String: Any] {
            guard let a = actual as? [String: Any] else { return "\(at) is not an object" }
            for (k, v) in e { if let bad = partial(a[k], v, "\(at).\(k)") { return bad } }
            return nil
        }
        // Numbers and booleans compare through their text, since the two
        // decoders bridge them differently on Darwin and Linux.
        let x = actual.map { "\($0)" } ?? "nil", y = expected.map { "\($0)" } ?? "nil"
        return x == y ? nil : "\(at) is \(x), wanted \(y)"
    }

    @Test func theFixtureIsThere() throws {
        #expect(!Self.data.isEmpty, "missing \(Self.fixtureURL.path)")
        let index = try Self.catalog()
        #expect(index.tracks.count == 11)
        #expect(index.collections.count == 6)
    }

    @Test(arguments: (try? JSONDecoder().decode(Fixture.self, from: OfflineQueryTests.data).cases) ?? [])
    func sharedCase(_ c: Case) throws {
        let index = try Self.catalog()
        let answer = OfflineQuery.answer(index, path: c.path, params: c.params.mapValues { $0.text }, random: { 0 })
        #expect(answer.status == (c.status ?? 200), "\(c.name)")
        #expect(answer.unknownRoute == (c.unknownRoute ?? false), "\(c.name)")
        let body = try JSONSerialization.jsonObject(with: answer.body, options: [.fragmentsAllowed])
        if let ids = c.ids {
            let items = (body as? [[String: Any]]) ?? ((body as? [String: Any])?["Items"] as? [[String: Any]]) ?? []
            #expect(items.compactMap { $0["Id"] as? String } == ids, "\(c.name)")
        }
        if let total = c.total {
            #expect((body as? [String: Any])?["TotalRecordCount"] as? Int == total, "\(c.name)")
        }
        let rawCase = ((Self.raw()["cases"] as? [[String: Any]]) ?? []).first { $0["name"] as? String == c.name }
        if let expected = rawCase?["body"] {
            let mismatch = Self.partial(body, expected, "body")
            #expect(mismatch == nil, "\(c.name): \(mismatch ?? "")")
        }
    }

    @Test func randomKeepsEveryItem() throws {
        let index = try Self.catalog()
        func ask(_ r: Double) throws -> [String] {
            let a = OfflineQuery.answer(index, path: "/Items", params: ["IncludeItemTypes": "Audio", "SortBy": "Random"], random: { r })
            let body = try JSONSerialization.jsonObject(with: a.body) as? [String: Any]
            return ((body?["Items"] as? [[String: Any]]) ?? []).compactMap { $0["Id"] as? String }
        }
        #expect(try ask(0).sorted() == ask(0.999).sorted())
        #expect(try ask(0) != ask(0.999))
    }

    @Test func aQueryStringOnThePathIsRead() throws {
        let a = OfflineQuery.answer(try Self.catalog(), path: "/Items?IncludeItemTypes=Playlist")
        let page = try JSON.decoder.decode(JfItemsResponse.self, from: a.body)
        #expect(page.items?.map(\.id) == ["pls1"])
    }

    @Test func anAnswerDecodesAsTheClientWould() throws {
        let a = OfflineQuery.answer(try Self.catalog(), path: "/Items/mov1", params: ["userId": "user1"])
        let movie = try JSON.decoder.decode(JfItem.self, from: a.body)
        #expect(movie.chapters?.count == 2)
        #expect(movie.mediaStreams?.last?.isExternal == true)
    }

    @Test func oneEngineAnswersManyRequestsAlike() throws {
        let index = try Self.catalog()
        let engine = OfflineQuery.Engine(index)
        // Compared as JSON values: the encoder does not promise a key order.
        func json(_ d: Data) throws -> NSObject? { try JSONSerialization.jsonObject(with: d) as? NSObject }
        for path in ["/Items/alb3", "/Artists", "/Items/gen1", "/Shows/shw1/Seasons", "/Items/alb3"] {
            #expect(try json(engine.answer(path: path).body) == json(OfflineQuery.answer(index, path: path).body), "\(path)")
        }
    }

    @Test func anEmptyCatalogAnswersEmptyLists() throws {
        for path in ["/Items", "/Artists", "/MusicGenres", "/UserViews", "/Shows/NextUp"] {
            let a = OfflineQuery.answer(OfflineIndex(), path: path)
            #expect(a.status == 200, "\(path)")
            #expect(try JSON.decoder.decode(JfItemsResponse.self, from: a.body).items?.isEmpty == true, "\(path)")
        }
        #expect(OfflineQuery.answer(OfflineIndex(), path: "/Users/me").status == 404)
    }

    @Test func jellyfinDatesWithSevenFractionalDigitsRead() {
        #expect(OfflineQuery.time("2026-10-01T08:00:00.1234567Z") == OfflineQuery.time("2026-10-01T08:00:00.123Z"))
        #expect(OfflineQuery.time("2026-10-01T08:00:00Z") == 1_790_841_600_000)
        #expect(OfflineQuery.time("soon") == nil)
        #expect(OfflineQuery.time("2026-10-01T10:00:00+02:00") == OfflineQuery.time("2026-10-01T08:00:00Z"))
        #expect(OfflineQuery.time("2026-10-01") == 1_790_812_800_000)
        #expect(OfflineQuery.time("1969-12-31T23:59:59Z") == -1000)
        #expect(OfflineQuery.time("2024-02-29T00:00:00Z") == 1_709_164_800_000)
        #expect(OfflineQuery.time("2026-13-01T00:00:00Z") == nil)
    }

    @Test func textSortsByScalarNotLocale() {
        #expect(OfflineQuery.cmpText("mira", "The") < 0)
        #expect(OfflineQuery.cmpText("Zeta", "échos") < 0)
        #expect(OfflineQuery.cmpText("a", "A") == 0)
    }
}

extension OfflineQueryTests.Case: CustomTestStringConvertible {
    var testDescription: String { name }
}
