import Foundation
import NaturalLanguage

// The pure parts of translating lyrics on the device: which language a lyric
// is in, whether it needs translating, the order lines are translated in, and
// the cache of translations kept between launches. The desktop's franc
// detection and src/core/translation-cache.ts, ported with their tests. The
// Translation framework itself, which needs a view to run in, is in the app
// (LyricsTranslation.swift); no lyric text leaves the phone.

public enum LyricTranslation {
    /// A translation is derived from the lyric text, so it is held no longer
    /// than the 25 days the lyrics themselves are (the Cascade Server plugin
    /// keeps SpicyLyrics for that long, and the desktop cache the same).
    public static let cacheLifetime: TimeInterval = 25 * 24 * 60 * 60
    public static let cacheMax = 5000

    /// Fewer letters than this and a guess is noise: a title line or a chorus
    /// of "la la la" must not become a confident "Latin".
    static let minimumCharacters = 12
    static let minimumConfidence = 0.6

    /// The language a lyric is written in, as a language code the Translation
    /// framework takes ("ja", "ko", "zh-Hans", "es"), or nil when unsure.
    /// Detected over the whole text at once: a single line is too short to tell.
    public static func detectLanguage(of lines: [String]) -> String? {
        let text = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard text.count >= minimumCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.value >= minimumConfidence, best.key != .undetermined else { return nil }
        return best.key.rawValue
    }

    /// Whether two codes name the same language. "en" and "en-US" do; "zh-Hans"
    /// and "zh-Hant" do not (a different script is a different translation),
    /// but a bare "zh" matches either.
    public static func sameLanguage(_ a: String, _ b: String) -> Bool {
        func parts(_ code: String) -> (language: String, script: String?) {
            let bits = code.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            let script = bits.dropFirst().first { $0.count == 4 }
            return (bits.first?.lowercased() ?? "", script?.lowercased())
        }
        let x = parts(a), y = parts(b)
        guard !x.language.isEmpty, x.language == y.language else { return false }
        if let sx = x.script, let sy = y.script { return sx == sy }
        return true
    }

    /// Whether lyrics in `source` should be offered a translation into
    /// `target`. An unknown source is not worth offering one for.
    public static func needsTranslation(from source: String?, to target: String) -> Bool {
        guard let source else { return false }
        return !sameLanguage(source, target)
    }

    /// The order to translate in: the current line, then onward to the end,
    /// then back through the lines before it. What is on screen comes first,
    /// and a person who joins a song halfway is not made to wait for its start.
    public static func order(count: Int, from current: Int?) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(current ?? 0, 0), count - 1)
        return Array(start..<count) + Array(0..<start)
    }

    /// A cache key. The target and source are in it, so a line translated into
    /// one language is never served as another.
    public static func cacheKey(source: String, target: String, line: String) -> String {
        "\(source.lowercased())>\(target.lowercased())|\(line)"
    }
}

/// Translations kept on the device between launches.
public struct TranslationCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        public var text: String
        public var at: Date
    }

    /// Oldest first, so trimming to the cap drops the oldest.
    public private(set) var entries: [Entry] = []
    private var index: [String: Int] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decode([Entry].self, forKey: .entries)
        reindex()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
    }

    private mutating func reindex() {
        index = [:]
        for (i, e) in entries.enumerated() { index[e.key] = i }
    }

    /// Whether an entry made at `at` still holds at `now`. A time in the future
    /// means the clock was wrong when it was written, which is not to be trusted.
    public static func isLive(_ at: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < LyricTranslation.cacheLifetime || (age < 0 && age > -60)
    }

    /// The translation, unless it is not there or has expired. Reading one does
    /// not extend it.
    public func translation(for key: String, now: Date = Date()) -> String? {
        guard let i = index[key], Self.isLive(entries[i].at, now: now) else { return nil }
        return entries[i].text
    }

    /// Stores a translation, replacing an older one for the same key.
    public mutating func set(_ text: String, for key: String, now: Date = Date()) {
        guard !key.isEmpty, key.count <= 4000, text.count <= 4000 else { return }
        if let i = index[key] { entries.remove(at: i) }
        entries.append(Entry(key: key, text: text, at: now))
        if entries.count > LyricTranslation.cacheMax { entries.removeFirst(entries.count - LyricTranslation.cacheMax) }
        reindex()
    }

    /// Drops what has expired. Run after loading: the file is read from disk,
    /// where it may be old, hand edited or from another build.
    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { Self.isLive($0.at, now: now) && !$0.key.isEmpty && $0.key.count <= 4000 && $0.text.count <= 4000 }
        if entries.count > LyricTranslation.cacheMax { entries.removeFirst(entries.count - LyricTranslation.cacheMax) }
        reindex()
    }

    /// A cache read from `data` (a missing or unreadable file is an empty one),
    /// already pruned.
    public static func decode(_ data: Data?, now: Date = Date()) -> TranslationCache {
        guard let data, var cache = try? JSONDecoder().decode(TranslationCache.self, from: data) else { return TranslationCache() }
        cache.prune(now: now)
        return cache
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
