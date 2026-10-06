import Testing
import Foundation
@testable import CascadeKit

// Ported from test/itunes-art.test.ts, plus the lookup cache and the 800 ms wait.
struct ITunesArtTests {
    func art(_ n: String) -> String { "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/\(n)/100x100bb.jpg" }
    func big(_ n: String) -> String { art(n).replacingOccurrences(of: "100x100bb", with: "600x600bb") }
    func r(_ name: String, _ artist: String) -> ITunesResult {
        ITunesResult(collectionName: name, artistName: artist, artworkUrl100: art(name))
    }

    @Test func exactAlbumMatchBeatsTheRelevantLookingFirstHit() {
        let results = [r("Hip Hop Takes On - Demon Days: The Tribute", "Various Artists"), r("Demon Days", "Gorillaz")]
        #expect(pickItunesArt(results, artist: "Gorillaz", album: "Demon Days") == big("Demon Days"))
    }

    @Test func punctuationAndAccentsDoNotBlockAnExactMatch() {
        #expect(pickItunesArt([r("DAMN.", "Kendrick Lamar")], artist: "Kendrick Lamar", album: "Damn") != nil)
        #expect(pickItunesArt([r("Café Bleu", "The Style Council")], artist: "The Style Council", album: "Cafe Bleu") != nil)
        #expect(pickItunesArt([r("Ágætis byrjun", "Sigur Rós")], artist: "Sigur Rós", album: "Ágætis byrjun") != nil)
    }

    @Test func editionSuffixStillMatchesButLosesToThePlainAlbum() {
        let results = [r("Kid A (Deluxe Edition)", "Radiohead"), r("Kid A", "Radiohead")]
        #expect(pickItunesArt(results, artist: "Radiohead", album: "Kid A") == big("Kid A"))
        #expect(pickItunesArt([results[0]], artist: "Radiohead", album: "Kid A") != nil)
    }

    @Test func artistOnlyBreaksTiesBetweenAlbumsOfTheSameName() {
        let results = [r("Home", "Some Other Band"), r("Home", "The Wanted")]
        #expect(pickItunesArt(results, artist: "The Wanted", album: "Home") == big("Home"))
        #expect(pickItunesArt([r("Home", "The Wanted")], artist: "Various Artists", album: "Home") != nil)
    }

    @Test func nothingMatchingMeansNoArtNotTheWrongArt() {
        #expect(pickItunesArt([r("Greatest Hits", "Queen")], artist: "Boards of Canada", album: "Geogaddi") == nil)
        #expect(pickItunesArt([], artist: "Anyone", album: "Anything") == nil)
        #expect(pickItunesArt(nil, artist: "Anyone", album: "Anything") == nil)
    }

    @Test func withNoAlbumNameTheArtistCarriesItAlone() {
        #expect(pickItunesArt([r("Whatever", "Aphex Twin")], artist: "Aphex Twin", album: "") != nil)
        #expect(pickItunesArt([r("Whatever", "Aphex Twin")], artist: "Autechre", album: "") == nil)
    }

    @Test func aResultWithNoArtworkIsSkipped() {
        let results = [ITunesResult(collectionName: "Kid A", artistName: "Radiohead"), r("Kid A", "Radiohead")]
        #expect(pickItunesArt(results, artist: "Radiohead", album: "Kid A") != nil)
    }

    @Test func collectionArtistNameWinsOverArtistName() {
        let rec = ITunesResult(collectionName: "Watch the Throne", collectionArtistName: "JAY-Z & Kanye West",
                               artistName: "Nobody", artworkUrl100: art("wtt"))
        #expect(pickItunesArt([rec], artist: "JAY-Z & Kanye West", album: "Watch the Throne") != nil)
    }

    @Test func artistMatchToleratesSpellingDriftButNotADifferentAct() {
        #expect(itunesArtistMatches("Panic! At the Disco", "Panic! At The Disco"))
        #expect(itunesArtistMatches("JAY-Z & Kanye West", "JAY Z & Kanye West"))
        #expect(!itunesArtistMatches("géraud", "Panic! At The Disco"))
        #expect(!itunesArtistMatches("R. Kelly", "Panic! At The Disco"))
        #expect(itunesArtistMatches("anything", ""))
    }

    @Test func theLofiCoversRecordDoesNotPassAsTheAlbum() {
        let results = [r("a fever you can't sweat out, but lofi", "géraud"), r("Chocolate Factory", "R. Kelly"),
                       r("The Getaway", "Red Hot Chili Peppers")]
        #expect(pickItunesArt(results, artist: "Panic! At The Disco", album: "A Fever You Can't Sweat Out") == nil)
    }

    @Test func lookupRecordsWithExtraFieldsMatchToo() {
        let results = [
            ITunesResult(artistName: "Panic! At the Disco", wrapperType: "artist"),
            ITunesResult(collectionName: "A Fever You Can't Sweat Out (20th Anniversary Deluxe)", artistName: "Panic! At the Disco", artworkUrl100: art("deluxe"), wrapperType: "collection"),
            ITunesResult(collectionName: "A Fever You Can't Sweat Out", artistName: "Panic! At the Disco", artworkUrl100: art("fever"), wrapperType: "collection"),
        ]
        #expect(pickItunesArt(results, artist: "Panic! At The Disco", album: "A Fever You Can't Sweat Out") == big("fever"))
    }

    // MARK: the cached lookup

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func body(_ rs: [ITunesResult]) -> Data {
        var items: [[String: Any]] = []
        for x in rs { items.append(["collectionName": x.collectionName ?? "", "artistName": x.artistName ?? "", "artworkUrl100": x.artworkUrl100 ?? ""]) }
        return try! JSONSerialization.data(withJSONObject: ["results": items])
    }

    @Test func aRateLimitedLookupIsNotRememberedButAnAnswerIs() async {
        let calls = Counter()
        let rec = r("Kid A", "Radiohead")
        let data = body([rec])
        let a = ITunesArt(fetch: { _ in (data, calls.bump() == 1 ? 403 : 200) })
        #expect(await a.art(artist: "Radiohead", album: "Kid A") == nil)
        #expect(await a.art(artist: "Radiohead", album: "Kid A") == big("Kid A"))
        #expect(await a.art(artist: "Radiohead", album: "Kid A") == big("Kid A"))
        #expect(calls.count == 2)
    }

    @Test func aRealMissIsRememberedAfterTheDiscographyFallback() async {
        let calls = Counter()
        let a = ITunesArt(fetch: { _ in _ = calls.bump(); return (Data(#"{"results":[]}"#.utf8), 200) })
        #expect(await a.art(artist: "Nobody", album: "Nothing") == nil)
        let first = calls.count
        #expect(await a.art(artist: "Nobody", album: "Nothing") == nil)
        #expect(calls.count == first)
    }

    @Test func slowLookupIsPendingThenAnswersFromTheSameFlight() async {
        let calls = Counter()
        let data = body([r("Kid A", "Radiohead")])
        let a = ITunesArt(fetch: { _ in _ = calls.bump(); try await Task.sleep(for: .milliseconds(300)); return (data, 200) })
        #expect(await a.art(artist: "Radiohead", album: "Kid A", within: 50) == .pending)
        #expect(await a.art(artist: "Radiohead", album: "Kid A") == big("Kid A"))
        #expect(await a.art(artist: "Radiohead", album: "Kid A", within: 800) == .found(big("Kid A")))
        #expect(calls.count == 1)
    }
}
