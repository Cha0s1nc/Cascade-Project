import Foundation

// Lyric parsing, ported from the desktop's src/core/lyrics.ts along with its
// tests (test/lyrics.test.ts). Keep the two in step: every branch below exists
// because a real file broke the version without it.
//
// All times are ticks, Jellyfin's convention: 100 ns, so 1 s = 10,000,000.

public struct LyricWord: Sendable, Equatable {
    public var start: Int
    /// The next word's start; the last word of a line takes the next line's.
    public var end: Int?
    public var text: String
}

public struct LyricLine: Sendable, Equatable {
    public var start: Int
    public var text: String
    /// Nil for plain LRC; set for karaoke (word-level) formats.
    public var words: [LyricWord]?
    /// Background vocals (SpicyLyrics), a smaller row under the lead with
    /// timings of their own.
    public var background: [LyricWord]? = nil
    /// A duet's second voice (SpicyLyrics' OppositeAligned), drawn on the right.
    public var opposite = false
}

public enum Lyrics {
    public static let ticksPerSecond = 10_000_000
    /// Used when the last line has no following line to borrow an end from.
    static let lastWordFallbackTicks = 2 * ticksPerSecond

    static func ticks(_ minutes: Substring, _ seconds: Substring) -> Int {
        // Rounded, like the desktop's Math.round: 10.53 * 1e7 is not exact in
        // floating point, and truncating would land a tick early.
        Int((((Double(minutes) ?? 0) * 60 + (Double(seconds) ?? 0)) * Double(ticksPerSecond)).rounded())
    }

    private static func hasLetterOrDigit(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    /// Standard LRC (`[mm:ss.xx]text`) or Enhanced LRC, the karaoke format
    /// (`[mm:ss.xx]<mm:ss.xx>word<mm:ss.xx>word...`). `.slrc` files from the
    /// Cascade Lyrics plugin are Enhanced LRC.
    public static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // Fractional seconds are optional. Requiring them silently dropped
            // every `[mm:ss]` line, a common style. Metadata tags ([ar:],
            // [offset:]) still fail the digits and are skipped.
            guard let m = raw.wholeMatch(of: /\[(\d+):(\d+(?:\.\d+)?)\](.*)/) else { continue }
            let start = ticks(m.1, m.2)
            let content = String(m.3)

            guard content.contains("<") else {
                let t = content.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { lines.append(LyricLine(start: start, text: t, words: nil)) }
                continue
            }

            var words: [LyricWord] = []
            // Per-character sources (.slrc, Chinese karaoke) give every space
            // its own timestamped token; dropping those runs the whole line
            // together. Tracked separately so a word's own trailing space is
            // still trimmed before punctuation.
            var pendingSpace = false
            for w in content.matches(of: /<(\d+):(\d+(?:\.\d+)?)>([^<\[]*)/) {
                let wText = String(w.3)
                if wText.isEmpty { continue }
                if wText.trimmingCharacters(in: .whitespaces).isEmpty { pendingSpace = !words.isEmpty; continue }

                // Punctuation with no letters or digits joins the previous
                // word, or karaoke shows a lone "!" as a lyric.
                if !hasLetterOrDigit(wText), !words.isEmpty, !pendingSpace {
                    let prev = words[words.count - 1].text
                    words[words.count - 1].text = trimEnd(prev) + trimStart(wText)
                } else {
                    if pendingSpace { words[words.count - 1].text += " " }
                    words.append(LyricWord(start: ticks(w.1, w.2), end: nil, text: wText))
                }
                pendingSpace = false
            }
            for i in words.indices.dropLast() { words[i].end = words[i + 1].start }

            let full = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { lines.append(LyricLine(start: start, text: full, words: words.isEmpty ? nil : words)) }
        }

        // Each line's last word ends where the next line starts.
        for i in lines.indices {
            guard let last = lines[i].words?.indices.last, lines[i].words?[last].end == nil else { continue }
            lines[i].words![last].end = i + 1 < lines.count
                ? lines[i + 1].start
                : lines[i].words![last].start + lastWordFallbackTicks
        }
        return lines
    }

    /// Index of the line playing at `positionTicks`, or nil before the first.
    /// Lines are in time order, so the answer is the last one already started.
    public static func activeLineIndex(_ lines: [LyricLine], at positionTicks: Int) -> Int? {
        lines.lastIndex { $0.start <= positionTicks }
    }

    /// A held note is at least this long.
    public static let emphasisMinTicks = ticksPerSecond

    /// Whether a word is a held note, to swell as it is sung: a second or
    /// longer, and short enough (1 to 12 letters or digits) to be one sung
    /// word rather than a run-on syllable. Only meaningful for SpicyLyrics,
    /// whose syllables carry real end times; parseLRC's end is the next
    /// word's start, so any word before a pause would look held. The
    /// desktop's isEmphasisWord (src/core/lyrics.ts).
    public static func isEmphasisWord(_ w: LyricWord) -> Bool {
        guard let end = w.end, end - w.start >= emphasisMinTicks else { return false }
        let letters = w.text.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.count
        return (1...12).contains(letters)
    }

    /// How far through a karaoke word the fill is at `positionTicks`, 0 to 1.
    /// The desktop's _wordProgress (lyric-karaoke.js).
    public static func wordProgress(_ word: LyricWord, at positionTicks: Int) -> Double {
        if positionTicks < word.start { return 0 }
        guard let end = word.end, positionTicks < end, end > word.start else { return 1 }
        return Double(positionTicks - word.start) / Double(end - word.start)
    }

    /// A line's signed distance from the current one: 0 is current, positive
    /// is upcoming, negative is past. Before the first line starts, every line
    /// counts as upcoming from an imaginary line -1, as on the desktop, so the
    /// first line waits one step away rather than looking already past.
    public static func lineDistance(_ index: Int, active: Int?) -> Int {
        index - (active ?? -1)
    }

    private static func trimEnd(_ s: String) -> String {
        String(s.reversed().drop { $0.isWhitespace }.reversed())
    }

    private static func trimStart(_ s: String) -> String {
        String(s.drop { $0.isWhitespace })
    }
}

// MARK: - Cascade Lyrics / Cascade Server plugin

/// Which route family the server's plugin answers on. The plugin was called
/// Cascade Lyrics before 2.0.0.0 (routes CascadeLyrics/*); it is Cascade
/// Server from then on (CascadeServer/*). Ported from the desktop's
/// src/core/cascade-plugin.ts.
public enum CascadePluginApi: Sendable, Equatable { case server, legacy }

public enum CascadePluginProbe: Sendable, Equatable { case present, absent, unknown }

public enum CascadePlugin {
    /// 200 means the plugin said so, 404 means the route (so the plugin) is
    /// missing. Anything else (401, 5xx, no network) says nothing, and is
    /// treated as present by callers: never hide a working feature because the
    /// network hiccuped.
    public static func interpret(_ status: Int?) -> CascadePluginProbe {
        switch status {
        case 200: .present
        case 404: .absent
        default: .unknown
        }
    }

    /// Combines the new-route probe with the old one, which is only asked
    /// when the new one said 404 (pass nil otherwise).
    public static func resolve(serverStatus: Int?, legacyStatus: Int?) -> (probe: CascadePluginProbe, api: CascadePluginApi) {
        let first = interpret(serverStatus)
        if first != .absent { return (first, .server) }
        return (interpret(legacyStatus), .legacy)
    }

    public static func lyricsPath(_ api: CascadePluginApi, itemId: String) -> String {
        api == .legacy ? "/Audio/\(itemId)/CascadeLyrics" : "/CascadeServer/Lyrics/\(itemId)"
    }
}

/// What the plugin's lyrics route returns: Enhanced LRC ("karaoke") or plain
/// timed LRC ("synced").
public struct PluginLyrics: Decodable, Sendable {
    public var lrc: String?
    public var type: String?
}

/// The lyrics for a track, and the SpicyLyrics credit when that is where
/// they came from (which the lyrics UI must show).
public struct ServerLyrics: Sendable, Equatable {
    public var lines: [LyricLine]
    public var credit: SpicyCredit?
}

/// What the plugin's Info route says it can do. "syllable" means a
/// SpicyLyrics key is set on the server, so asking for them is worth it.
private struct PluginInfo: Decodable {
    var capabilities: [String]?
}

public extension JellyfinClient {
    /// Which plugin build the server runs, asked once per session: the new
    /// Info route, then the pre-rename one on a 404. rogserver still runs
    /// Cascade Lyrics 1.0.0.0, which only answers the legacy routes.
    /// Also returns the capabilities it reports; a plugin too old to send
    /// them reports none.
    func probeCascadePlugin() async -> (probe: CascadePluginProbe, api: CascadePluginApi, capabilities: Set<String>) {
        func status(_ path: String) async -> (Int?, Set<String>) {
            do {
                let info: PluginInfo = try await get(path)
                return (200, Set(info.capabilities ?? []))
            }
            catch let e as JellyfinError { return (e.status == 0 ? nil : e.status, []) }
            catch { return (nil, []) }
        }
        let server: Int?
        var capabilities: Set<String>
        (server, capabilities) = await status("/CascadeServer/Info")
        var legacy: Int?
        if server == 404 { (legacy, capabilities) = await status("/CascadeLyrics/Info") }
        let (probe, api) = CascadePlugin.resolve(serverStatus: server, legacyStatus: legacy)
        return (probe, api, capabilities)
    }

    /// The plugin's lyrics for a track, parsed. Nil when it has none: the
    /// lyrics route answers a bare 404 for that, which is not an error here.
    ///
    /// With `spicy` (the plugin reports a SpicyLyrics key), asks for those
    /// first (`syllable=true`); the plugin answers them only when it can
    /// match the track, and otherwise falls through to its own files in the
    /// same reply. A SpicyLyrics sync that is for another release of the song
    /// (SpicyLyrics.fitsTrack), or that will not convert, is set aside and the
    /// plugin's own files asked for instead, as on the desktop: better those
    /// than nothing.
    func serverLyrics(itemId: String, api: CascadePluginApi, spicy: Bool,
                      durationSeconds: Double) async throws -> ServerLyrics? {
        let path = CascadePlugin.lyricsPath(api, itemId: itemId)
        func parsed(_ lrc: String?) -> ServerLyrics? {
            let lines = Lyrics.parseLRC(lrc ?? "")
            return lines.isEmpty ? nil : ServerLyrics(lines: lines, credit: nil)
        }
        do {
            if spicy {
                let data = try await getData(path, params: ["syllable": "true"])
                let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                if reply?["type"] as? String == "syllable" {
                    if SpicyLyrics.fitsTrack(reply?["spicy"], durationSeconds: durationSeconds),
                       let conv = SpicyLyrics.convert(reply?["spicy"]) {
                        return ServerLyrics(lines: conv.lines, credit: conv.credit)
                    }
                } else if let reply {
                    return parsed(reply["lrc"] as? String)
                }
            }
            let reply: PluginLyrics = try await get(path)
            return parsed(reply.lrc)
        } catch let e as JellyfinError where e.status == 404 {
            return nil
        }
    }
}
