import Foundation

// SpicyLyrics API response -> Cascade's lyric lines, plus the credit the API's
// terms require wherever those lyrics are shown. Ported from the desktop's
// src/core/spicy-lyrics.ts with its tests; keep the two in step.
//
// Shape, from the reference's OpenAPI schema:
//   Body.Type 'Syllable' -> Content[] of { Lead: {Syllables[]}, Background?: [...] }
//   Body.Type 'Line'     -> Content[] of { Text, StartTime, EndTime }
//   Body.Type 'Static'   -> Lines[] of { Text }
// Every time is SECONDS as a float; Cascade keeps ticks.
//
// OppositeAligned marks a duet's second voice. Deliberately not used:
// TranslatedText and TransliteratedText.

public struct SpicyContributor: Sendable, Equatable {
    public var name: String
    /// https only: this came from a third party and is handed to the OS.
    public var url: URL?
}

/// What the lyrics UI must show next to SpicyLyrics lyrics. `provider` is
/// always shown; uploader and maker only exist for a community sync.
public struct SpicyCredit: Sendable, Equatable {
    public var provider: String
    public var uploader: SpicyContributor?
    public var maker: SpicyContributor?
}

public struct SpicyConversion: Sendable, Equatable {
    public var lines: [LyricLine]
    public var credit: SpicyCredit
}

public enum SpicyLyrics {
    private typealias Obj = [String: Any]

    private static let providerLabels = [
        "spicy_lyrics": "Spicy Lyrics",
        "apple_music": "Apple Music via Spicy Lyrics",
        "spotify": "Spotify via Spicy Lyrics",
    ]

    /// How far past the end of the file a sync may run before it is taken to
    /// be for a different version: slack for rounding and trailing silence.
    public static let endToleranceSeconds = 1.5

    /// The whole envelope or just its Body.
    private static func body(_ raw: Any?) -> Obj? {
        guard let o = raw as? Obj else { return nil }
        return o["Body"] as? Obj ?? o
    }

    /// Seconds to ticks, or nil for anything that is not a usable time.
    private static func ticks(_ v: Any?) -> Int? {
        guard let d = v as? Double, d.isFinite, d >= 0 else { return nil }
        return Int((d * Double(Lyrics.ticksPerSecond)).rounded())
    }

    public static func safeCreditURL(_ v: Any?) -> URL? {
        guard let s = v as? String, let url = URL(string: s),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func contributor(_ v: Any?) -> SpicyContributor? {
        guard let o = v as? Obj else { return nil }
        let name = (o["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : SpicyContributor(name: name, url: safeCreditURL(o["url"]))
    }

    /// The credit for a response. Uploader and maker are read only for a
    /// community sync, as the terms say; for a commercial source they are
    /// absent even if sent.
    public static func credit(_ raw: Any?) -> SpicyCredit {
        let b = body(raw) ?? [:]
        let source = b["source"] as? String ?? ""
        let attribution = source == "spicy_lyrics" ? b["UploadAttribution"] as? Obj : nil
        return SpicyCredit(provider: providerLabels[source] ?? "Spicy Lyrics",
                           uploader: contributor(attribution?["Uploader"]),
                           maker: contributor(attribution?["Maker"]))
    }

    /// One vocal group's syllables as words. IsPartOfWord joins a syllable to
    /// the next with no space; otherwise a word carries its trailing space,
    /// as parseLRC's do. Each syllable keeps its own end time, so the gaps
    /// between words survive (Enhanced LRC could not carry them).
    private static func groupWords(_ group: Any?) -> [LyricWord] {
        guard let g = group as? Obj else { return [] }
        let syllables = g["Syllables"] as? [Any] ?? []
        var out: [LyricWord] = []
        var prevEnd = ticks(g["StartTime"])
        for (i, raw) in syllables.enumerated() {
            guard let s = raw as? Obj, let text = s["Text"] as? String, !text.isEmpty,
                  // No time at all: it cannot be placed on the clock.
                  let start = ticks(s["StartTime"]) ?? prevEnd else { continue }
            let end = ticks(s["EndTime"])
            let joined = s["IsPartOfWord"] as? Bool == true || i == syllables.count - 1
            out.append(LyricWord(start: start, end: end, text: text + (joined ? "" : " ")))
            prevEnd = end ?? start
        }
        return out
    }

    private static func opposite(_ c: Obj) -> Bool { c["OppositeAligned"] as? Bool == true }

    private static func syllableLines(_ content: [Any]) -> [LyricLine] {
        content.compactMap { raw in
            guard let c = raw as? Obj else { return nil }
            let words = groupWords(c["Lead"])
            guard let first = words.first else { return nil }
            // Background vocals get a row of their own under the lead; merged
            // in, two fills ran across one line at once. Several phrases on a
            // line join into one row, each keeping its own timings.
            var background: [LyricWord] = []
            for bg in c["Background"] as? [Any] ?? [] {
                let bw = groupWords(bg)
                guard !bw.isEmpty else { continue }
                if let last = background.indices.last {
                    background[last].text = background[last].text.trimmingCharacters(in: .whitespaces) + " "
                }
                background += bw
            }
            let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return LyricLine(start: ticks((c["Lead"] as? Obj)?["StartTime"]) ?? first.start, text: text, words: words,
                             background: background.isEmpty ? nil : background, opposite: opposite(c))
        }
    }

    private static func lineLines(_ content: [Any]) -> [LyricLine] {
        content.compactMap { raw in
            guard let c = raw as? Obj, let start = ticks(c["StartTime"]) else { return nil }
            let text = (c["Text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : LyricLine(start: start, text: text, words: nil, opposite: opposite(c))
        }
    }

    /// Lines plus the credit to show, or nil when there is nothing usable, so
    /// the caller falls back to the plugin's own files.
    ///
    /// ponytail: 'Static' (untimed) bodies come back nil, since LyricLine has
    /// no untimed form yet; the plugin's own files are asked instead. Add them
    /// with the rest of the lyric waterfall, which has LRCLIB's plain lyrics.
    public static func convert(_ raw: Any?) -> SpicyConversion? {
        guard let b = body(raw) else { return nil }
        let lines: [LyricLine]
        switch b["Type"] as? String {
        case "Syllable": lines = syllableLines(b["Content"] as? [Any] ?? [])
        case "Line": lines = lineLines(b["Content"] as? [Any] ?? [])
        default: return nil
        }
        return lines.isEmpty ? nil : SpicyConversion(lines: lines, credit: credit(b))
    }

    /// Whether a sync can belong to the file being played. A sync is keyed to
    /// a Spotify track, and the id found can belong to another release (a
    /// longer edit, a remaster) whose timings drift against this file. Vocals
    /// cannot end after the track does, so a sync running past the file's end
    /// is another version: a 190.7 s sync against a 186.6 s file ran 3.5 s
    /// late at the first verse and 8 s late by the end. Only catches a LONGER
    /// version. Nothing to judge (no EndTime, no duration) passes.
    public static func fitsTrack(_ raw: Any?, durationSeconds: Double) -> Bool {
        guard let end = body(raw)?["EndTime"] as? Double, end.isFinite, durationSeconds > 0 else { return true }
        return end <= durationSeconds + endToleranceSeconds
    }
}
