import Testing
@testable import CascadeKit

// Ported case for case from the desktop's test/lyrics.test.ts, so the two
// parsers cannot drift apart without one of them failing.
private let sec = Lyrics.ticksPerSecond

struct ParseLRCTests {
    @Test func plainLinesCarryNoWordTiming() {
        let out = Lyrics.parseLRC("[00:12.50]Hello world")
        #expect(out == [LyricLine(start: 12 * sec + sec / 2, text: "Hello world", words: nil)])
    }

    @Test func wholeSecondTimestampsAreValid() {
        // Regression: fractional seconds used to be mandatory, and every
        // `[mm:ss]` line was dropped with no error.
        let out = Lyrics.parseLRC("[00:12]hello")
        #expect(out.map(\.start) == [12 * sec])
        #expect(out.map(\.text) == ["hello"])
    }

    @Test func mixedWholeAndFractionalLines() {
        let out = Lyrics.parseLRC("[00:10]one\n[00:12.50]two\n[00:15]three")
        #expect(out.map(\.text) == ["one", "two", "three"])
        #expect(out.map(\.start) == [10 * sec, 12 * sec + sec / 2, 15 * sec])
    }

    @Test func wordTimestampsAllowWholeSeconds() {
        let words = Lyrics.parseLRC("[00:10]<00:10>Hello <00:11.5>world")[0].words
        #expect(words?.map(\.start) == [10 * sec, 11 * sec + sec / 2])
    }

    @Test func skipsMetadataAndBlankContent() {
        let out = Lyrics.parseLRC("[ti:Some Title]\n[ar:Artist]\n[00:01.00]\n[00:02.00]real")
        #expect(out.map(\.text) == ["real"])
    }

    @Test func enhancedWordEndsChainToTheNextWord() {
        let out = Lyrics.parseLRC("[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:12.50]next")
        #expect(out.count == 2)
        #expect(out[0].text == "Hello world")
        let w = out[0].words!
        #expect(w.count == 2)
        #expect(w[0].start == 10 * sec)
        #expect(w[0].end == 10 * sec + sec / 2)
        #expect(w[1].start == 10 * sec + sec / 2)
        #expect(w[1].end == 12 * sec + sec / 2)   // borrows the next line's start
    }

    @Test func finalWordFallsBackTwoSeconds() {
        let w = Lyrics.parseLRC("[00:10.00]<00:10.00>only")[0].words!
        #expect(w[0].end == 12 * sec)
    }

    @Test func barePunctuationJoinsThePreviousWord() {
        let w = Lyrics.parseLRC("[00:01.00]<00:01.00>hey<00:01.50>!")[0].words!
        #expect(w.map(\.text) == ["hey!"])
    }

    @Test func perCharacterSourcesKeepTheirSpaces() {
        #expect(Lyrics.parseLRC("[00:01.00]<00:01.00>a<00:01.10> <00:01.20>b")[0].text == "a b")
    }

    @Test func timestampsRoundLikeTheDesktop() {
        #expect(Lyrics.parseLRC("[00:10.53]x")[0].start == 105_300_000)
    }

    @Test func windowsLineEndings() {
        #expect(Lyrics.parseLRC("[00:01]one\r\n[00:02]two").map(\.text) == ["one", "two"])
    }

    @Test func activeLineIsTheLastOneStarted() {
        let lines = Lyrics.parseLRC("[00:01]a\n[00:05]b\n[00:09]c")
        #expect(Lyrics.activeLineIndex(lines, at: 0) == nil)
        #expect(Lyrics.activeLineIndex(lines, at: 5 * sec) == 1)
        #expect(Lyrics.activeLineIndex(lines, at: 60 * sec) == 2)
    }
}

// Ported from the desktop's test/cascade-plugin.test.ts.
struct CascadePluginTests {
    @Test func statusMeaning() {
        #expect(CascadePlugin.interpret(200) == .present)
        #expect(CascadePlugin.interpret(404) == .absent)
        #expect(CascadePlugin.interpret(401) == .unknown)
        #expect(CascadePlugin.interpret(nil) == .unknown)
    }

    @Test func newRouteFirstThenLegacy() {
        #expect(CascadePlugin.resolve(serverStatus: 200, legacyStatus: nil) == (.present, .server))
        #expect(CascadePlugin.resolve(serverStatus: 404, legacyStatus: 401) == (.unknown, .legacy))
        #expect(CascadePlugin.resolve(serverStatus: 404, legacyStatus: 404) == (.absent, .legacy))
        // An unknown on the new route says nothing about the build: stay current.
        #expect(CascadePlugin.resolve(serverStatus: 500, legacyStatus: nil) == (.unknown, .server))
    }

    @Test func lyricsRoutes() {
        #expect(CascadePlugin.lyricsPath(.legacy, itemId: "x") == "/Audio/x/CascadeLyrics")
        #expect(CascadePlugin.lyricsPath(.server, itemId: "x") == "/CascadeServer/Lyrics/x")
    }

    @Test func wordProgressFillsAcrossTheWord() {
        let w = LyricWord(start: 100, end: 200, text: "word ")
        #expect(Lyrics.wordProgress(w, at: 50) == 0)
        #expect(Lyrics.wordProgress(w, at: 150) == 0.5)
        #expect(Lyrics.wordProgress(w, at: 200) == 1)
        // No end means "sung once started", never a division by zero.
        #expect(Lyrics.wordProgress(LyricWord(start: 100, end: nil, text: "x"), at: 101) == 1)
    }

    @Test func linesBeforeTheFirstAreAllUpcoming() {
        #expect(Lyrics.lineDistance(0, active: nil) == 1)
        #expect(Lyrics.lineDistance(3, active: 3) == 0)
        #expect(Lyrics.lineDistance(1, active: 3) == -2)
        #expect(Lyrics.lineDistance(5, active: 3) == 2)
    }
}
