import Foundation

// The lyrics editor's document model with LRC / Enhanced LRC import and export, ported from
// lyrics-editor.html (parseLRCText, exportLRC, ticksToLRC). Unlike Lyrics.parseLRC, which
// shapes lyrics for display (merging punctuation, dropping spacing tokens), this keeps what a
// person typed: a word keeps its trailing space, and the lines stay editable. Times are
// seconds, since the editor works against a player clock.

public struct LRCWord: Sendable, Equatable {
    public var start: Double?
    public var end: Double?
    public var text: String
    public init(start: Double? = nil, end: Double? = nil, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public struct LRCLine: Sendable, Equatable {
    public var start: Double?
    public var text: String
    /// Nil for a plain line; set once a line has word timings (or was split into words).
    public var words: [LRCWord]?
    public init(start: Double? = nil, text: String, words: [LRCWord]? = nil) {
        self.start = start; self.text = text; self.words = words
    }
}

public enum LRCDocument {
    /// `mm:ss.xx` as written to a file. Rounded to centiseconds before splitting, so 59.996 is
    /// "01:00.00" and never the invalid "00:60.00" that formatting the seconds alone gives.
    public static func stamp(_ seconds: Double?) -> String {
        let c = max(Int(((seconds ?? 0) * 100).rounded()), 0)
        return String(format: "%02d:%02d.%02d", c / 6000, (c / 100) % 60, c % 100)
    }

    /// Time shown in the editor, `m:ss.mmm`, or "-" for none.
    public static func display(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "-" }
        return String(format: "%d:%06.3f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// The reverse of `display`: `m:ss.mmm`, or plain seconds. Nil for anything else.
    public static func seconds(fromDisplay text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "-" { return nil }
        if let m = t.wholeMatch(of: /(\d+):(\d+(?:\.\d*)?)/) {
            return (Double(m.1) ?? 0) * 60 + (Double(m.2) ?? 0)
        }
        return Double(t)
    }

    private static func time(_ minutes: Substring, _ seconds: Substring) -> Double {
        (Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)
    }

    /// Standard and Enhanced LRC. A line is `[mm:ss.xx]text` or `[mm:ss.xx]<mm:ss.xx>word <mm:ss.xx>word`.
    /// Metadata tags ([ar:], [offset:]), lines without a leading time tag and empty lines are
    /// skipped. A word's trailing space is kept: it is the separator in the enhanced format.
    public static func parse(_ text: String) -> [LRCLine] {
        var lines: [LRCLine] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let m = trimmed.wholeMatch(of: /\[(\d+):(\d+(?:\.\d+)?)\](.*)/) else { continue }
            let start = time(m.1, m.2)
            let rest = String(m.3)

            var words: [LRCWord] = []
            for w in rest.matches(of: /<(\d+):(\d+(?:\.\d+)?)>([^<]*)/) {
                let wText = String(w.3)
                if wText.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                words.append(LRCWord(start: time(w.1, w.2), text: wText))
            }
            // Best effort: a word ends where the next begins.
            for i in words.indices.dropLast() { words[i].end = words[i + 1].start }

            if !words.isEmpty {
                let full = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                lines.append(LRCLine(start: start, text: full, words: words))
            } else {
                let plain = rest.replacing(/<[^>]*>/, with: "").trimmingCharacters(in: .whitespaces)
                if plain.isEmpty { continue }
                lines.append(LRCLine(start: start, text: plain))
            }
        }
        return lines
    }

    /// Enhanced LRC for a line with words, plain LRC otherwise. Words are separated by one
    /// space each (added when an edit dropped it); the last has none. A missing time exports as zero.
    public static func export(_ lines: [LRCLine]) -> String {
        lines.map { line in
            let head = "[\(stamp(line.start))]"
            guard let words = line.words, !words.isEmpty else { return head + line.text }
            let body = words.enumerated().map { i, w in
                var t = w.text
                if i < words.count - 1 { if !t.hasSuffix(" ") { t += " " } }
                else { t = String(t.reversed().drop { $0.isWhitespace }.reversed()) }
                return "<\(stamp(w.start))>\(t)"
            }.joined()
            return head + body
        }.joined(separator: "\n")
    }

    /// Splits a plain line into untimed words, as the editor's "Split to words" does.
    public static func split(_ line: LRCLine) -> LRCLine? {
        let parts = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty { return nil }
        var out = line
        out.words = parts.map { LRCWord(text: $0) }
        return out
    }

    /// One thing Stamp mode stamps: a word, or a whole line that has no words.
    public enum StampTarget: Sendable, Equatable { case word(line: Int, word: Int), line(Int) }

    /// Stamp mode's walk through the document, in order.
    public static func stampSequence(_ lines: [LRCLine]) -> [StampTarget] {
        lines.indices.flatMap { li -> [StampTarget] in
            if let words = lines[li].words, !words.isEmpty { return words.indices.map { .word(line: li, word: $0) } }
            return [.line(li)]
        }
    }

    /// Stamps step `index` of `sequence` at `now`, and fills the previous word's end with the
    /// same time, so the word before a stamp stops where the next one starts.
    public static func stamp(_ lines: inout [LRCLine], sequence: [StampTarget], index: Int, at now: Double) {
        guard sequence.indices.contains(index) else { return }
        if index > 0, case .word(let l, let w) = sequence[index - 1], lines.indices.contains(l),
           lines[l].words?.indices.contains(w) == true {
            lines[l].words![w].end = now
        }
        switch sequence[index] {
        case .word(let l, let w):
            if lines.indices.contains(l), lines[l].words?.indices.contains(w) == true { lines[l].words![w].start = now }
        case .line(let l):
            if lines.indices.contains(l) { lines[l].start = now }
        }
    }

    /// The line and word showing at `t`: the last of each that has started.
    public static func active(_ lines: [LRCLine], at t: Double) -> (line: Int, word: Int?)? {
        guard let li = lines.lastIndex(where: { ($0.start ?? .infinity) <= t }) else { return nil }
        let wi = lines[li].words?.lastIndex { ($0.start ?? .infinity) <= t }
        return (li, wi)
    }
}
