import Foundation

/// Release notes are Markdown written on GitHub. This reads the part of it
/// they actually use: headings, nested lists (tab or space indented),
/// paragraphs, rules, and inline bold, italics, strikethrough, code and
/// links. The desktop's release-notes.js, producing blocks for SwiftUI
/// instead of HTML.
///
/// Nothing in a release body can inject anything: it only ever becomes text
/// attributes, and only http(s) URLs become links.
///
/// ponytail: a subset, not CommonMark. No tables, blockquotes, images or
/// reference links; swap in a real parser if the notes ever need them.
public enum ReleaseNotes {
    public struct ListItem: Equatable, Sendable {
        public var text: AttributedString
        public var children: [Block]
    }

    public indirect enum Block: Equatable, Sendable {
        case heading(Int, AttributedString)
        case paragraph(AttributedString)
        case list(ordered: Bool, items: [ListItem])
        case rule
    }

    // MARK: Inline

    private struct Rule {
        let find: (Substring, Character?) -> (range: Range<Substring.Index>, make: () -> AttributedString)?
    }

    private static func styled(_ text: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var s = inline(text)
        for run in s.runs {
            let existing = s[run.range].inlinePresentationIntent ?? []
            s[run.range].inlinePresentationIntent = existing.union(intent)
        }
        return s
    }

    private static func isWord(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }

    /// Matches `pattern` whose only capture is the span text, wrapped as `intent`.
    private static func emphasis(_ pattern: Regex<(Substring, Substring)>, _ intent: InlinePresentationIntent,
                                 wordBoundary: Bool = false) -> Rule {
        Rule { s, before in
            var from = s.startIndex
            while from < s.endIndex, let m = s[from...].firstMatch(of: pattern) {
                if wordBoundary {
                    let prev = m.range.lowerBound == s.startIndex ? before : s[s.index(before: m.range.lowerBound)]
                    let next = m.range.upperBound < s.endIndex ? s[m.range.upperBound] : nil
                    if isWord(prev) || isWord(next) { from = s.index(after: m.range.lowerBound); continue }
                }
                let inner = String(m.1)
                return (m.range, { styled(inner, intent) })
            }
            return nil
        }
    }

    nonisolated(unsafe) private static let rules: [Rule] = [
        // Code spans and links are tried first so the emphasis rules cannot
        // reach into them (a URL can contain * or _).
        Rule { s, _ in
            guard let m = s.firstMatch(of: /`([^`]+)`/) else { return nil }
            let code = String(m.1)
            return (m.range, { var a = AttributedString(code); a.inlinePresentationIntent = .code; return a })
        },
        Rule { s, _ in
            guard let m = s.firstMatch(of: /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/) else { return nil }
            let label = String(m.1), url = String(m.2)
            return (m.range, {
                var a = inline(label)
                if let u = URL(string: url) { a.link = u }
                return a
            })
        },
        Rule { s, before in
            // A bare URL, after whitespace, an opening paren or the start.
            var from = s.startIndex
            while from < s.endIndex, let m = s[from...].firstMatch(of: /(https?:\/\/[^\s<)]+)/) {
                let prev = m.range.lowerBound == s.startIndex ? before : s[s.index(before: m.range.lowerBound)]
                if let prev, !prev.isWhitespace, prev != "(" { from = s.index(after: m.range.lowerBound); continue }
                let url = String(m.1)
                return (m.range, {
                    var a = AttributedString(url)
                    if let u = URL(string: url) { a.link = u }
                    return a
                })
            }
            return nil
        },
        emphasis(/\*\*\*(\S(?:.*?\S)?)\*\*\*/, [.stronglyEmphasized, .emphasized]),
        emphasis(/\*\*(\S(?:.*?\S)?)\*\*/, .stronglyEmphasized),
        emphasis(/__(\S(?:.*?\S)?)__/, .stronglyEmphasized, wordBoundary: true),
        emphasis(/~~(\S(?:.*?\S)?)~~/, .strikethrough),
        emphasis(/\*([^*\s](?:[^*]*?[^*\s])?)\*/, .emphasized),
        emphasis(/_([^_\s](?:[^_]*?[^_\s])?)_/, .emphasized, wordBoundary: true),
    ]

    /// One line or paragraph of text with its inline Markdown applied.
    public static func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        var before: Character?
        while !rest.isEmpty {
            var best: (range: Range<Substring.Index>, make: () -> AttributedString)?
            for rule in rules {
                if let m = rule.find(rest, before), best == nil || m.range.lowerBound < best!.range.lowerBound { best = m }
            }
            guard let best else { out += AttributedString(String(rest)); break }
            out += AttributedString(String(rest[rest.startIndex..<best.range.lowerBound]))
            out += best.make()
            before = rest[best.range.lowerBound..<best.range.upperBound].last
            rest = rest[best.range.upperBound...]
        }
        return out
    }

    // MARK: Blocks

    private static func indent(of whitespace: Substring) -> Int {
        whitespace.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private struct OpenItem { var raw: String; var children: [Block] = [] }
    private struct OpenList { var indent: Int; var ordered: Bool; var items: [OpenItem] }

    /// Parses a release body. Empty for a body with nothing in it.
    public static func parse(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var stack: [OpenList] = []
        // Consecutive text lines are one paragraph: CHANGELOG.md wraps its lines.
        var para: [String] = []

        func closePara() {
            if !para.isEmpty { blocks.append(.paragraph(inline(para.joined(separator: " ")))) }
            para = []
        }
        func popList() {
            let list = stack.removeLast()
            let block = Block.list(ordered: list.ordered,
                                   items: list.items.map { ListItem(text: inline($0.raw), children: $0.children) })
            if stack.isEmpty { blocks.append(block) } else { stack[stack.count - 1].items[stack[stack.count - 1].items.count - 1].children.append(block) }
        }
        func closeLists(above: Int = -1) {
            while let top = stack.last, top.indent > above { popList() }
        }

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let t = String(rawLine).replacing(/\s+$/, with: "")
            if let m = t.wholeMatch(of: /(\s*)([-*+]|[0-9]+[.)])\s+(.*)/), !isRule(t) {
                closePara()
                let level = indent(of: m.1)
                let ordered = m.2.first?.isNumber ?? false
                closeLists(above: level)
                if let top = stack.last, top.indent == level {
                    stack[stack.count - 1].items.append(OpenItem(raw: String(m.3)))
                } else {
                    stack.append(OpenList(indent: level, ordered: ordered, items: [OpenItem(raw: String(m.3))]))
                }
            } else if !t.trimmingCharacters(in: .whitespaces).isEmpty, !stack.isEmpty, t.first?.isWhitespace == true {
                // An indented line under a list item continues that item, as a
                // soft wrap: GitHub joins it with a space, and CHANGELOG.md
                // wraps long items.
                stack[stack.count - 1].items[stack[stack.count - 1].items.count - 1].raw += " " + t.trimmingCharacters(in: .whitespaces)
            } else {
                closeLists()
                if t.trimmingCharacters(in: .whitespaces).isEmpty { closePara(); continue }
                if let m = t.wholeMatch(of: /(#{1,6})\s+(.*)/) {
                    closePara()
                    blocks.append(.heading(m.1.count, inline(String(m.2))))
                } else if isRule(t) {
                    closePara()
                    blocks.append(.rule)
                } else {
                    para.append(t.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        closePara()
        closeLists()
        return blocks
    }
}
