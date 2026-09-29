import Foundation

// The desktop's lyric waterfall (renderer.js _lyricsWaterfall), minus its
// forced-source picker: where a track's lyrics come from.
//
// - Server-only: the Cascade plugin alone, SpicyLyrics first when the server
//   has a key, then the plugin's own files.
// - Otherwise all at once, first usable answer in this order: SpicyLyrics
//   (through the plugin, spicyOnly so a miss costs nothing), Kugou (only when
//   it has word timings), LRCLIB (synced, then plain), Jellyfin's own lyrics.
//   An instrumental flag from any of them wins, as on the desktop.

/// Lyrics for a track and where they came from.
public struct LyricsResult: Sendable, Equatable {
    public var lines: [LyricLine]
    /// Set for SpicyLyrics, whose terms want it on screen with the lyrics.
    public var credit: SpicyCredit?
    /// False for untimed lyrics (LRCLIB's plain lyrics, a SpicyLyrics Static
    /// sync, untimed Jellyfin lyrics), shown as a still page. Their lines'
    /// starts mean nothing.
    public var synced: Bool
    public var source: String
    /// The track is known to have no vocals; `lines` is empty.
    public var instrumental: Bool

    public init(lines: [LyricLine], credit: SpicyCredit? = nil, synced: Bool = true, source: String,
                instrumental: Bool = false) {
        self.lines = lines
        self.credit = credit
        self.synced = synced
        self.source = source
        self.instrumental = instrumental
    }

    static let instrumentalTrack = LyricsResult(lines: [], source: "LRCLIB", instrumental: true)
}

/// What the plugin's Info route says: what it can do, and whether this user's
/// Spotify links apply to the whole server.
public struct CascadePluginInfo: Decodable, Sendable, Equatable {
    public var capabilities: Set<String>
    public var spotifyLinkServerWide: Bool

    public init(capabilities: Set<String> = [], spotifyLinkServerWide: Bool = true) {
        self.capabilities = capabilities
        self.spotifyLinkServerWide = spotifyLinkServerWide
    }

    enum CodingKeys: String, CodingKey { case capabilities, spotifyLinkServerWide }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = Set(try c.decodeIfPresent([String].self, forKey: .capabilities) ?? [])
        // A plugin from before the setting existed sends nothing, and there
        // any user could link songs for everyone.
        spotifyLinkServerWide = try c.decodeIfPresent(Bool.self, forKey: .spotifyLinkServerWide) ?? true
    }

    /// A SpicyLyrics key is set on the server.
    public var spicy: Bool { capabilities.contains("syllable") }
    public var spotifyLink: Bool { capabilities.contains("spotify-link") }
}

public extension Lyrics {
    /// Kugou's KRC: `[lineStartMs,lineDurMs]<offsetMs,durMs,0>text...`, word
    /// offsets relative to the line. The desktop's parseKrc.
    ///
    /// One difference: KRC puts the space before a word (" there"), and here
    /// it moves to the end of the word before, the convention parseLRC and
    /// the karaoke layout use, so words group and wrap the same way.
    static func parseKrc(_ text: String) -> [LyricLine] {
        let ms = ticksPerSecond / 1000
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Tags ([ti:], [offset:]) fail the digits and are skipped.
            guard let m = line.wholeMatch(of: /\[(\d+),(\d+)\](.*)/), let lineStart = Int(m.1) else { continue }
            var words: [LyricWord] = []
            for w in m.3.matches(of: /<(\d+),(\d+),\d+>([^<]*)/) {
                guard let offset = Int(w.1), let duration = Int(w.2) else { continue }
                var text = String(w.3)
                guard !text.isEmpty else { continue }
                let lead = text.prefix { $0.isWhitespace }
                if !lead.isEmpty, !words.isEmpty {
                    words[words.count - 1].text += lead
                    text.removeFirst(lead.count)
                }
                guard !text.isEmpty else { continue }
                words.append(LyricWord(start: (lineStart + offset) * ms, end: (lineStart + offset + duration) * ms,
                                       text: text))
            }
            let full = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { lines.append(LyricLine(start: lineStart * ms, text: full, words: words.isEmpty ? nil : words)) }
        }
        return lines
    }

    /// Drops the credits some sources put in the lyrics: a "Title - " opening
    /// line, and "Composed by:", "Written by:", 作词: and the like.
    static func droppingCredits(_ lines: [LyricLine], title: String) -> [LyricLine] {
        let credit = /^(?i:composed|written|produced|arranged|performed|lyrics|music|words|publisher|作词|作曲|编曲|编词|制作人)\s*(?i:by)?\s*[:：]/
        return lines.filter { line in
            if line.text.firstMatch(of: credit) != nil { return false }
            guard !title.isEmpty, line.text.lowercased().hasPrefix(title.lowercased()) else { return true }
            let rest = line.text.dropFirst(title.count)
            return rest.firstMatch(of: /^\s*-\s*/) == nil
        }
    }

    /// Plain text, one line each, for an untimed sheet.
    static func plainLines(_ text: String) -> [LyricLine] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(start: 0, text: $0, words: nil) }
    }
}

/// Kugou's lyrics service: word-level KRC, no account needed.
public enum Kugou {
    private static let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]

    /// A download's `content`: base64 of "krc1", then the rest XORed with a
    /// fixed key, which gives a zlib stream. Foundation's .zlib is the raw
    /// DEFLATE inside it, so the 2-byte header and 4-byte checksum come off.
    public static func decrypt(base64 content: String) -> String? {
        guard let data = Data(base64Encoded: content), data.count > 10 else { return nil }
        var bytes = [UInt8](data.dropFirst(4))
        for i in bytes.indices { bytes[i] ^= key[i % key.count] }
        let deflate = Data(bytes[2..<(bytes.count - 4)]) as NSData
        guard let out = try? deflate.decompressed(using: .zlib) else { return nil }
        return String(data: out as Data, encoding: .utf8)
    }

    /// The best match's lyrics as KRC text, or nil.
    public static func krc(title: String, artist: String, durationMs: Int, session: URLSession = .shared) async throws -> String? {
        var search = URLComponents(string: "https://lyrics.kugou.com/search")!
        search.queryItems = [.init(name: "ver", value: "1"), .init(name: "man", value: "yes"), .init(name: "client", value: "pc"),
                             .init(name: "keyword", value: "\(artist) - \(title)"), .init(name: "duration", value: String(durationMs))]
        let (sData, _) = try await session.data(from: search.url!)
        guard let first = ((try? JSONSerialization.jsonObject(with: sData)) as? [String: Any])?["candidates"] as? [[String: Any]],
              let candidate = first.first, let id = candidate["id"], let accessKey = candidate["accesskey"] as? String
        else { return nil }
        var download = URLComponents(string: "https://lyrics.kugou.com/download")!
        download.queryItems = [.init(name: "ver", value: "1"), .init(name: "client", value: "pc"),
                               .init(name: "id", value: "\(id)"), .init(name: "accesskey", value: accessKey),
                               .init(name: "fmt", value: "krc"), .init(name: "charset", value: "utf8")]
        let (dData, _) = try await session.data(from: download.url!)
        guard let content = ((try? JSONSerialization.jsonObject(with: dData)) as? [String: Any])?["content"] as? String
        else { return nil }
        return decrypt(base64: content)
    }
}

/// LRCLIB, the open lyrics database: synced LRC, else plain text.
public enum LRCLIB {
    public static func lyrics(title: String, artist: String, album: String, durationSeconds: Int,
                              userAgent: String, session: URLSession = .shared) async throws -> LyricsResult? {
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [.init(name: "artist_name", value: artist), .init(name: "track_name", value: title),
                          .init(name: "album_name", value: album), .init(name: "duration", value: String(durationSeconds))]
        var request = URLRequest(url: url.url!)
        // LRCLIB asks every client to say who it is.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(reply)
    }

    static func parse(_ reply: [String: Any]) -> LyricsResult? {
        if reply["instrumental"] as? Bool == true { return .instrumentalTrack }
        if let synced = reply["syncedLyrics"] as? String {
            let lines = Lyrics.parseLRC(synced)
            if !lines.isEmpty { return LyricsResult(lines: lines, source: "LRCLIB") }
        }
        if let plain = reply["plainLyrics"] as? String {
            let lines = Lyrics.plainLines(plain)
            if !lines.isEmpty { return LyricsResult(lines: lines, synced: false, source: "LRCLIB (plain)") }
        }
        return nil
    }
}

/// Jellyfin's own lyrics route: `{ Lyrics: [{ Start?, Text }] }`.
private struct JellyfinLyrics: Decodable {
    struct Line: Decodable { var start: Int?; var text: String? }
    var lyrics: [Line]?
}

public extension JellyfinClient {
    /// The server's own lyrics (embedded or sidecar files Jellyfin found).
    /// Untimed when any line has no start.
    func jellyfinLyrics(itemId: String) async throws -> LyricsResult? {
        do {
            let reply: JellyfinLyrics = try await get("/Audio/\(itemId)/Lyrics")
            let lines = (reply.lyrics ?? []).compactMap { l -> (Int?, String)? in
                guard let t = l.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
                return (l.start, t)
            }
            guard !lines.isEmpty else { return nil }
            let synced = lines.allSatisfy { $0.0 != nil }
            return LyricsResult(lines: lines.map { LyricLine(start: $0.0 ?? 0, text: $0.1, words: nil) },
                                synced: synced, source: "Jellyfin")
        } catch let e as JellyfinError where e.status == 404 {
            return nil
        }
    }

    /// What a song is linked to on the server: its Spotify id, and whether a
    /// person set it (then it can be removed) rather than the lookup.
    func spotifyLink(itemId: String) async throws -> (spotifyId: String?, manual: Bool) {
        struct Reply: Decodable { var spotifyId: String?; var manual: Bool? }
        let reply: Reply = try await get("/CascadeServer/SpotifyId/\(itemId)")
        return (reply.spotifyId, reply.manual ?? false)
    }

    /// Links a song to a Spotify track for everyone on the server. Throws the
    /// server's reason on a refusal (403 when this user may not).
    func setSpotifyLink(itemId: String, spotifyId: String) async throws {
        struct Body: Encodable { var spotifyId: String }
        _ = try await postRaw("/CascadeServer/SpotifyId/\(itemId)", body: Body(spotifyId: spotifyId))
    }

    func removeSpotifyLink(itemId: String) async throws {
        _ = try await delete("/CascadeServer/SpotifyId/\(itemId)")
    }
}

public enum LyricsWaterfall {
    /// What the waterfall needs to know about the track.
    public struct Track: Sendable {
        public var id: String
        public var title: String
        public var artist: String
        public var album: String
        public var durationSeconds: Double

        public init(id: String, title: String, artist: String, album: String, durationSeconds: Double) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.durationSeconds = durationSeconds
        }
    }

    /// - plugin: the plugin's route family and Info, or nil when it is absent
    ///   (then server-only has nothing to ask, and is ignored).
    /// - spotifyId: a link this user made for this song on this device only.
    public static func fetch(_ track: Track, client: JellyfinClient, plugin: (api: CascadePluginApi, info: CascadePluginInfo)?,
                             serverOnly: Bool, spotifyId: String?, userAgent: String) async -> LyricsResult? {
        if serverOnly, let plugin {
            let result = try? await client.serverLyrics(itemId: track.id, api: plugin.api, spicy: plugin.info.spicy,
                                                         durationSeconds: track.durationSeconds, spotifyId: spotifyId)
            return result.map { r in
                var r = r
                if r.credit == nil { r.lines = Lyrics.droppingCredits(r.lines, title: track.title) }
                return r.lines.isEmpty ? nil : r
            } ?? nil
        }

        async let spicy: LyricsResult? = {
            guard let plugin, plugin.info.spicy else { return nil }
            return try? await client.serverLyrics(itemId: track.id, api: plugin.api, spicy: true,
                                                  durationSeconds: track.durationSeconds, spotifyId: spotifyId,
                                                  spicyOnly: true)
        }()
        async let kugou: LyricsResult? = {
            guard let krc = try? await Kugou.krc(title: track.title, artist: track.artist,
                                                 durationMs: Int(track.durationSeconds * 1000)) else { return nil }
            let lines = Lyrics.droppingCredits(Lyrics.parseKrc(krc), title: track.title)
            // Only with word timings; otherwise LRCLIB's lines are as good.
            return lines.contains { !($0.words ?? []).isEmpty } ? LyricsResult(lines: lines, source: "Kugou") : nil
        }()
        async let lrclib = try? LRCLIB.lyrics(title: track.title, artist: track.artist, album: track.album,
                                              durationSeconds: Int(track.durationSeconds.rounded()), userAgent: userAgent)
        async let jellyfin = try? client.jellyfinLyrics(itemId: track.id)

        let (s, k, l, j) = await (spicy, kugou, lrclib ?? nil, jellyfin ?? nil)
        if l?.instrumental == true { return l }
        return s ?? k ?? l ?? j
    }
}

public enum Spotify {
    /// The track id in whatever a person pastes: a share link (with or
    /// without an /intl-xx/ or /embed/ segment and ?si=), a spotify:track:
    /// URI, or the bare 22-character id. Nil for anything else, albums and
    /// playlists included. The desktop's parseSpotifyTrackId.
    public static func trackId(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.wholeMatch(of: /[A-Za-z0-9]{22}/) != nil { return s }
        if let m = s.wholeMatch(of: /spotify:track:([A-Za-z0-9]{22})/) { return String(m.1) }
        if let m = s.wholeMatch(of: /(?i:(?:https?:\/\/)?open\.spotify\.com\/(?:intl-[a-z-]+\/)?(?:embed\/)?track\/)([A-Za-z0-9]{22})(?:[\/?#].*)?/) {
            return String(m.1)
        }
        return nil
    }
}
