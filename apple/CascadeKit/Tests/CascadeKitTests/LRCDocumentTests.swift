import Testing
@testable import CascadeKit

struct LRCDocumentTests {
    @Test func plainLineRoundTrips() {
        let text = "[00:12.50]Hello world\n[01:05.07]Second line"
        let lines = LRCDocument.parse(text)
        #expect(lines.count == 2)
        #expect(lines[0].start == 12.5)
        #expect(lines[1].start == 65.07)
        #expect(lines[0].words == nil)
        #expect(LRCDocument.export(lines) == text)
    }

    @Test func enhancedLineKeepsWordTimingsAndSpaces() {
        let text = "[00:10.00]<00:10.00>Till <00:10.40>the <00:11.00>end"
        let lines = LRCDocument.parse(text)
        let words = try! #require(lines[0].words)
        #expect(words.map(\.text) == ["Till ", "the ", "end"])
        #expect(words.map(\.start) == [10, 10.4, 11])
        // A word ends where the next starts; the last has no end until stamped.
        #expect(words[0].end == 10.4)
        #expect(words[2].end == nil)
        #expect(lines[0].text == "Till the end")
        #expect(LRCDocument.export(lines) == text)
    }

    @Test func metadataBlankAndUntimedLinesAreSkipped() {
        let lines = LRCDocument.parse("[ar:Someone]\n[offset:200]\n\nno tag here\n[00:01.00]kept\n[00:02.00]   \n")
        #expect(lines.map(\.text) == ["kept"])
    }

    @Test func untimedWordTagsAreStrippedFromPlainLines() {
        let lines = LRCDocument.parse("[00:03.00]a <b> c")
        #expect(lines[0].text == "a  c")
        #expect(lines[0].words == nil)
    }

    @Test func exportAddsMissingWordSpacingAndTrimsTheLast() {
        let line = LRCLine(start: 1, text: "ab cd", words: [LRCWord(start: 1, text: "ab"), LRCWord(start: 2, text: "cd  ")])
        #expect(LRCDocument.export([line]) == "[00:01.00]<00:01.00>ab <00:02.00>cd")
    }

    @Test func untimedExportsAsZero() {
        #expect(LRCDocument.export([LRCLine(text: "x")]) == "[00:00.00]x")
    }

    @Test func stampRoundsToCentisecondsWithoutOverflowingTheSecond() {
        #expect(LRCDocument.stamp(59.996) == "01:00.00")
        #expect(LRCDocument.stamp(3599.5) == "59:59.50")
        #expect(LRCDocument.stamp(-1) == "00:00.00")
        #expect(LRCDocument.stamp(nil) == "00:00.00")
    }

    @Test func displayAndParseOfEditorTimes() {
        #expect(LRCDocument.display(75.25) == "1:15.250")
        #expect(LRCDocument.display(nil) == "-")
        #expect(LRCDocument.seconds(fromDisplay: "1:15.25") == 75.25)
        #expect(LRCDocument.seconds(fromDisplay: "12.5") == 12.5)
        #expect(LRCDocument.seconds(fromDisplay: "-") == nil)
        #expect(LRCDocument.seconds(fromDisplay: "abc") == nil)
    }

    @Test func splitMakesUntimedWords() {
        let split = LRCDocument.split(LRCLine(start: 4, text: "one  two three"))
        #expect(split?.words?.map(\.text) == ["one", "two", "three"])
        #expect(split?.words?.allSatisfy { $0.start == nil } == true)
        #expect(LRCDocument.split(LRCLine(text: "   ")) == nil)
    }

    @Test func stampingWalksWordsThenLinesAndFillsThePreviousEnd() {
        var lines = [
            LRCLine(text: "a b", words: [LRCWord(text: "a"), LRCWord(text: "b")]),
            LRCLine(text: "plain"),
        ]
        let seq = LRCDocument.stampSequence(lines)
        #expect(seq == [.word(line: 0, word: 0), .word(line: 0, word: 1), .line(1)])
        LRCDocument.stamp(&lines, sequence: seq, index: 0, at: 1)
        LRCDocument.stamp(&lines, sequence: seq, index: 1, at: 2)
        LRCDocument.stamp(&lines, sequence: seq, index: 2, at: 3)
        #expect(lines[0].words?[0].start == 1)
        #expect(lines[0].words?[0].end == 2)
        #expect(lines[0].words?[1].start == 2)
        // The next step, a line here, still closes the word before it.
        #expect(lines[0].words?[1].end == 3)
        #expect(lines[1].start == 3)
    }

    @Test func activeFindsTheLastStartedLineAndWord() {
        let lines = [
            LRCLine(start: 1, text: "a b", words: [LRCWord(start: 1, text: "a"), LRCWord(start: 2, text: "b")]),
            LRCLine(start: 5, text: "c"),
        ]
        #expect(LRCDocument.active(lines, at: 0.5) == nil)
        #expect(LRCDocument.active(lines, at: 2.5)?.line == 0)
        #expect(LRCDocument.active(lines, at: 2.5)?.word == 1)
        #expect(LRCDocument.active(lines, at: 6)?.line == 1)
        #expect(LRCDocument.active(lines, at: 6)?.word == nil)
    }
}
