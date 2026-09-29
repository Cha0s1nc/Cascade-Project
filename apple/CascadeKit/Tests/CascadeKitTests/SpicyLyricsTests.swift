import Foundation
import Testing
@testable import CascadeKit

// Ported from the desktop's test/spicy-lyrics.test.ts. Fixtures are JSON text
// run through JSONSerialization, as the plugin's reply is, so numbers arrive
// as the NSNumbers the converter really sees.
private let sec = Lyrics.ticksPerSecond

private func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) }

private let syllableBody = """
{"Type": "Syllable", "id": "1QV6tiMFM6fSOKOGLMHYYg", "source": "spicy_lyrics",
 "UploadAttribution": {
   "Uploader": {"id": "1", "username": "spikerko", "url": "https://spicylyrics.org/uid/1"},
   "Maker": {"id": "2", "username": "gc", "url": "https://spicylyrics.org/uid/2"}},
 "Content": [{"Type": "Vocal",
   "Lead": {"StartTime": 7.357, "EndTime": 9.5, "Syllables": [
     {"Text": "Hel", "StartTime": 7.357, "EndTime": 7.6, "IsPartOfWord": true},
     {"Text": "lo", "StartTime": 7.6, "EndTime": 7.9},
     {"Text": "world", "StartTime": 8.2, "EndTime": 9.5}]},
   "Background": [{"Syllables": [{"Text": "oh", "StartTime": 8.5, "EndTime": 9.0}]}]}]}
"""

struct SpicyLyricsTests {
    @Test func syllableSyncTicksJoinsAndKeepsGaps() throws {
        let out = try #require(SpicyLyrics.convert(json("{\"Body\": \(syllableBody), \"Status\": 200}")))
        let line = try #require(out.lines.first)
        #expect(line.start == 73_570_000)
        #expect(line.text == "Hello world")
        #expect(line.words?.map(\.text) == ["Hel", "lo ", "world"])
        // Background vocals are their own row, with their own timing.
        #expect(line.background?.map(\.text) == ["oh"])
        #expect(line.background?.map(\.start) == [85_000_000])
        // "lo" ends at 7.9 and "world" starts at 8.2: the pause is kept.
        #expect(line.words?[1].end == 79_000_000)
        #expect(line.words?[2].start == 82_000_000)
        #expect(line.opposite == false)
    }

    @Test func acceptsTheBareBody() {
        #expect(SpicyLyrics.convert(json(syllableBody))?.lines.count == 1)
    }

    @Test func untimedSyllableBorrowsPreviousEndAndTimelessGroupIsDropped() throws {
        let out = try #require(SpicyLyrics.convert(json("""
        {"Type": "Syllable", "source": "spicy_lyrics", "Content": [
          {"Lead": {"Syllables": [{"Text": "a", "StartTime": 1, "EndTime": 2}, {"Text": "b"}]}},
          {"Lead": {"Syllables": [{"Text": "lost"}]}}]}
        """)))
        #expect(out.lines.count == 1)
        #expect(out.lines[0].words?[1].start == 2 * sec)
    }

    @Test func lineSyncKeepsTimedLinesOnly() throws {
        let out = try #require(SpicyLyrics.convert(json("""
        {"Type": "Line", "source": "apple_music", "Content": [
          {"Type": "Vocal", "Text": "first (echo)", "StartTime": 1.5, "EndTime": 3}, {"Text": "no time"}]}
        """)))
        #expect(out.lines == [LyricLine(start: 15_000_000, text: "first (echo)", words: nil)])
    }

    @Test func nothingUsableIsNil() {
        for junk in ["null", "\"x\"", "{}", "{\"Type\": \"Karaoke\"}", "{\"Type\": \"Syllable\", \"Content\": []}",
                     "{\"Body\": {\"Type\": \"Static\", \"Lines\": []}}"] {
            #expect(SpicyLyrics.convert(json(junk)) == nil, "\(junk)")
        }
    }

    @Test func communityCreditNamesUploaderAndMaker() {
        #expect(SpicyLyrics.credit(json(syllableBody)) == SpicyCredit(
            provider: "Spicy Lyrics",
            uploader: SpicyContributor(name: "spikerko", url: URL(string: "https://spicylyrics.org/uid/1")),
            maker: SpicyContributor(name: "gc", url: URL(string: "https://spicylyrics.org/uid/2"))))
    }

    @Test func absentMakerIsNoMaker() {
        let c = SpicyLyrics.credit(json("""
        {"source": "spicy_lyrics", "UploadAttribution": {"Uploader": {"username": "spikerko"}}}
        """))
        #expect(c.maker == nil)
        #expect(c.uploader?.name == "spikerko")
    }

    @Test func commercialSourceShowsOnlyTheProvider() {
        let apple = syllableBody.replacingOccurrences(of: "\"spicy_lyrics\"", with: "\"apple_music\"")
        #expect(SpicyLyrics.credit(json(apple)) == SpicyCredit(provider: "Apple Music via Spicy Lyrics"))
        #expect(SpicyLyrics.credit(json("{\"source\": \"something-new\"}")).provider == "Spicy Lyrics")
    }

    @Test func creditLinksAreHttpsOnly() {
        #expect(SpicyLyrics.safeCreditURL("https://spicylyrics.org/uid/1")?.absoluteString == "https://spicylyrics.org/uid/1")
        for bad: Any in ["http://x.org", "javascript:alert(1)", "file:///etc/passwd", "not a url", 42, NSNull()] {
            #expect(SpicyLyrics.safeCreditURL(bad) == nil, "\(bad)")
        }
        let c = SpicyLyrics.credit(json("""
        {"source": "spicy_lyrics", "UploadAttribution": {"Uploader": {"username": "x", "url": "javascript:alert(1)"}}}
        """))
        #expect(c.uploader == SpicyContributor(name: "x", url: nil))
    }

    @Test func aSyncRunningPastTheFileIsAnotherVersion() {
        // The real case: Apple Music sync to 190.73 s, local file 186.6 s.
        #expect(!SpicyLyrics.fitsTrack(json("{\"Body\": {\"EndTime\": 190.73}}"), durationSeconds: 186.6))
        #expect(SpicyLyrics.fitsTrack(json("{\"EndTime\": 185}"), durationSeconds: 186.6))
        #expect(SpicyLyrics.fitsTrack(json("{\"EndTime\": 187.5}"), durationSeconds: 186.6))   // inside the slack
    }

    @Test func nothingToJudgeFits() {
        #expect(SpicyLyrics.fitsTrack(json("{\"Body\": {}}"), durationSeconds: 186.6))
        #expect(SpicyLyrics.fitsTrack(json("{\"Body\": {\"EndTime\": 999}}"), durationSeconds: 0))
        #expect(SpicyLyrics.fitsTrack(nil, durationSeconds: 186.6))
    }

    @Test func aDuetKeepsWhichVoiceSingsEachLine() throws {
        // Shaped like the real "Dracula (JENNIE Remix)" sync.
        func vocal(_ text: String, _ t: Int, _ opposite: Bool) -> String {
            """
            {"Type": "Vocal", "OppositeAligned": \(opposite), "Lead": {"StartTime": \(t), "EndTime": \(t + 1),
             "Syllables": [{"Text": "\(text)", "StartTime": \(t), "EndTime": \(t + 1)}]}}
            """
        }
        let out = try #require(SpicyLyrics.convert(json(
            "{\"Type\": \"Syllable\", \"source\": \"spicy_lyrics\", \"Content\": [\(vocal("Tame", 1, false)), \(vocal("Jennie", 3, true))]}")))
        #expect(out.lines.map(\.opposite) == [false, true])

        let lineSync = try #require(SpicyLyrics.convert(json("""
        {"Type": "Line", "source": "spicy_lyrics", "Content": [
          {"Text": "first voice", "StartTime": 1, "EndTime": 2, "OppositeAligned": false},
          {"Text": "second voice", "StartTime": 3, "EndTime": 4, "OppositeAligned": true}]}
        """)))
        #expect(lineSync.lines.map(\.opposite) == [false, true])
    }

    @Test func heldNotesAreASecondOrLongerAndShort() {
        #expect(Lyrics.isEmphasisWord(LyricWord(start: 0, end: sec, text: "now")))
        #expect(!Lyrics.isEmphasisWord(LyricWord(start: 0, end: sec - 1, text: "now")))
        #expect(!Lyrics.isEmphasisWord(LyricWord(start: 0, end: nil, text: "now")))
        #expect(!Lyrics.isEmphasisWord(LyricWord(start: 0, end: 2 * sec, text: "...")))
        #expect(!Lyrics.isEmphasisWord(LyricWord(start: 0, end: 2 * sec, text: "supercalifragilistic")))
    }
}
