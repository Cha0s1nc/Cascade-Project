import Testing
@testable import CascadeKit

// Ported from the desktop's test for topSongsOf.
struct ArtistPageTests {
    private func song(_ name: String, plays: Int?) -> JfItem {
        JfItem(id: name, name: name, type: "Audio", userData: plays.map { JfUserData(playCount: $0) })
    }

    @Test func mostPlayedFirstTiesByNameUnplayedLeftOut() {
        let songs = [song("b", plays: 3), song("a", plays: 3), song("c", plays: 9), song("never", plays: 0),
                     song("unknown", plays: nil)]
        #expect(ArtistPage.topSongs(songs).map(\.name) == ["c", "a", "b"])
    }

    @Test func capsAtTen() {
        let songs = (1...15).map { (n: Int) in song("s\(n)", plays: n) }
        #expect(ArtistPage.topSongs(songs).count == 10)
        #expect(ArtistPage.topSongs(songs).first?.name == "s15")
    }

    @Test func anArtistNobodyPlayedHasNone() {
        #expect(ArtistPage.topSongs([song("a", plays: 0), song("b", plays: nil)]).isEmpty)
    }
}
