import Foundation

/// CHANGELOG.md, read into data: the desktop's src/core/changelog.ts, the
/// half the updater needs (parse, read the website's JSON, `notesBetween`).
///
/// One file lists every stable release of every platform, newest first:
///
///     ## 2.3.0 (2026-10-05)
///     ### Desktop
///     - ...
///     ### Mac
///     - ...
///
/// Platform sections are optional per version. Betas are not listed. The
/// parser is strict and says which line is wrong, so a typo in a heading
/// fails loudly instead of quietly dropping a version.
public enum Changelog {
    public enum Platform: String, CaseIterable, Sendable {
        case desktop, mac, apple, android

        var title: String {
            switch self {
            case .desktop: "Desktop"
            case .mac: "Mac"
            case .apple: "Apple"
            case .android: "Android"
            }
        }
    }

    public struct Entry: Equatable, Sendable {
        public var version: String
        /// YYYY-MM-DD, the day the release was published.
        public var date: String
        /// Markdown per platform, without its `###` heading.
        public var platforms: [Platform: String]

        public init(version: String, date: String, platforms: [Platform: String] = [:]) {
            self.version = version
            self.date = date
            self.platforms = platforms
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible, Sendable {
        public var line: Int
        public var message: String
        public var description: String { "CHANGELOG.md line \(line): \(message)" }
    }

    // A release version only: no leading zeros, no beta suffix.
    nonisolated(unsafe) private static let versionHeading = /## ((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)) \(([0-9]{4}-[0-9]{2}-[0-9]{2})\)/

    private static func isRealDate(_ date: String) -> Bool {
        let p = date.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: d)
        return back.year == p[0] && back.month == p[1] && back.day == p[2]
    }

    /// Drops blank lines at both ends, keeping everything between as written.
    private static func trimBlankLines(_ lines: [String]) -> String {
        var start = 0, end = lines.count
        while start < end, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        while end > start, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return lines[start..<end].map { $0.replacing(/\s+$/, with: "") }.joined(separator: "\n")
    }

    private static func fenceMarker(_ line: String) -> String? {
        line.firstMatch(of: /^ {0,3}(```|~~~)/).map { String($0.1) }
    }

    /// Parses CHANGELOG.md. Anything before the first version heading (a
    /// title, an introduction) is ignored. Throws a ParseError on anything
    /// that does not follow the format.
    public static func parse(_ markdown: String) throws -> [Entry] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [Entry] = []
        var entry: Entry?
        var entryLine = 0
        var platform: Platform?
        var platformLine = 0
        var body: [String] = []
        var fence: String?
        var fenceLine = 0

        func closePlatform() throws {
            guard entry != nil, let p = platform else { return }
            let text = trimBlankLines(body)
            if text.isEmpty { throw ParseError(line: platformLine, message: "the \(p.title) section of \(entry!.version) is empty") }
            entry!.platforms[p] = text
            platform = nil
            body = []
        }
        func closeEntry() throws {
            try closePlatform()
            if let e = entry {
                if e.platforms.isEmpty {
                    throw ParseError(line: entryLine, message: "\(e.version) has no ### Desktop, ### Mac, ### Apple or ### Android section")
                }
                entries.append(e)
            }
            entry = nil
        }

        for (i, raw) in lines.enumerated() {
            let n = i + 1
            let line = raw.replacing(/\s+$/, with: "")

            // Headings inside a code block are text.
            let marker = fenceMarker(line)
            if let open = fence {
                if marker == open { fence = nil }
                if platform != nil { body.append(raw) }
                continue
            }
            if let marker { fence = marker; fenceLine = n }

            if line.firstMatch(of: /^#{1,3}(\s|$)/) != nil {
                if line.hasPrefix("## ") || line == "##" {
                    guard let m = line.wholeMatch(of: versionHeading) else {
                        throw ParseError(line: n, message: "expected a version heading like \"## 2.3.0 (2026-10-05)\", found \"\(line)\"")
                    }
                    let version = String(m.1), date = String(m.2)
                    if !isRealDate(date) { throw ParseError(line: n, message: "\(date) is not a real date") }
                    if entries.contains(where: { $0.version == version }) || entry?.version == version {
                        throw ParseError(line: n, message: "\(version) is listed twice")
                    }
                    if let previous = entry ?? entries.last, !UpdateRelease.isNewerVersion(previous.version, than: version) {
                        throw ParseError(line: n, message: "\(version) is below \(previous.version), but versions must be newest first")
                    }
                    try closeEntry()
                    entry = Entry(version: version, date: date)
                    entryLine = n
                    continue
                }
                if line.hasPrefix("### ") || line == "###" {
                    guard let e = entry else { throw ParseError(line: n, message: "\"\(line)\" comes before any version heading") }
                    guard let key = Platform.allCases.first(where: { line == "### \($0.title)" }) else {
                        throw ParseError(line: n, message: "expected \"### Desktop\", \"### Mac\", \"### Apple\" or \"### Android\", found \"\(line)\"")
                    }
                    if e.platforms[key] != nil || platform == key {
                        throw ParseError(line: n, message: "\(e.version) has two \(key.title) sections")
                    }
                    try closePlatform()
                    platform = key
                    platformLine = n
                    continue
                }
                // A top-level "# " heading: the title, before any version, is fine.
                if let e = entry {
                    throw ParseError(line: n, message: "a \"# \" heading inside \(e.version); use #### for headings within a section")
                }
                continue
            }

            if platform != nil {
                body.append(raw)
            } else if let e = entry, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ParseError(line: n, message: "text in \(e.version) before its first ### Desktop, ### Mac, ### Apple or ### Android heading")
            }
        }

        if fence != nil { throw ParseError(line: fenceLine, message: "this code block is never closed") }
        try closeEntry()
        return entries
    }

    /// The entry for a version (a leading "v" is ignored), or nil.
    public static func find(_ entries: [Entry], version: String) -> Entry? {
        let want = version.hasPrefix("v") ? String(version.dropFirst()) : version
        return entries.first { $0.version == want }
    }

    // Caps for changelog.json read from the website: well above any real
    // file, low enough that a broken or hostile one cannot flood the window.
    private static let jsonMaxEntries = 500
    private static let jsonMaxNotes = 20_000

    /// changelog.json (the parsed CHANGELOG.md the website serves) checked
    /// back into entries, or nil if anything in it is not shaped like one. It
    /// comes over the network, so every field is checked, not trusted.
    public static func fromJSON(_ data: Data) -> [Entry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let list = object as? [Any],
              list.count <= jsonMaxEntries else { return nil }
        var entries: [Entry] = []
        for raw in list {
            guard let e = raw as? [String: Any], let version = e["version"] as? String, let date = e["date"] as? String,
                  "## \(version) (\(date))".wholeMatch(of: versionHeading) != nil, isRealDate(date),
                  let platforms = e["platforms"] as? [String: Any] else { return nil }
            var out: [Platform: String] = [:]
            for p in Platform.allCases {
                guard let value = platforms[p.rawValue] else { continue }
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= jsonMaxNotes else { return nil }
                out[p] = text
            }
            entries.append(Entry(version: version, date: date, platforms: out))
        }
        return entries
    }

    /// What changed for one platform after `current`, up to and including
    /// `target`, newest first, each version under its own `##` heading.
    ///
    /// Nil when the changelog does not list `target` at all: that copy is
    /// older than the release (the website updates after it), so the caller
    /// tries another copy rather than show notes missing the version on
    /// offer. Empty when it lists `target` but has nothing for this platform
    /// in the range; then the release's own notes say more.
    public static func notesBetween(_ entries: [Entry], platform: Platform, current: String, target: String) -> String? {
        guard entries.contains(where: { $0.version == target }) else { return nil }
        return entries
            .filter { $0.platforms[platform] != nil && UpdateRelease.isNewerVersion($0.version, than: current)
                && !UpdateRelease.isNewerVersion($0.version, than: target) }
            .sorted { UpdateRelease.isNewerVersion($0.version, than: $1.version) }
            .map { "## \($0.version) (\($0.date))\n\n\($0.platforms[platform]!)" }
            .joined(separator: "\n\n")
    }
}
