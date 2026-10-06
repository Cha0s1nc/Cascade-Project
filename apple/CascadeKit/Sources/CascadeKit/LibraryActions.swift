import Foundation

// The library writes the context menus and the metadata editor make: refresh,
// delete, edit, download, plus the media info and stream URL they show. Routes
// read from the server's spec; every call throws on a bad status.

// MARK: - Media info

/// What the media info sheet reads. Jellyfin 10.11 keeps the file's size,
/// container and bitrate on the MEDIA SOURCE (the item itself has the
/// container but no size), so the desktop's top-level `Size` read showed a
/// dash for every track; this looks at the source first.
public struct MediaDetail: Decodable, Sendable {
    public struct Stream: Decodable, Sendable {
        public var type: String?
        public var codec: String?
        public var bitRate: Int?
        public var sampleRate: Int?
        public var channels: Int?
    }
    public struct Source: Decodable, Sendable {
        public var container: String?
        public var size: Int?
        public var bitrate: Int?
        public var mediaStreams: [Stream]?
    }
    public var name: String?
    public var albumArtist: String?
    public var artists: [String]?
    public var album: String?
    public var productionYear: Int?
    public var indexNumber: Int?
    public var runTimeTicks: Int?
    public var container: String?
    public var size: Int?
    public var dateCreated: String?
    public var userData: JfUserData?
    public var mediaStreams: [Stream]?
    public var mediaSources: [Source]?

    public init(name: String? = nil) { self.name = name }
}

public enum MediaInfo {
    /// The sheet's fourteen rows, in the desktop's order. A value that is
    /// missing (a nil, an empty string) leaves its row out, except the ones
    /// the desktop shows as a dash.
    public static func rows(_ d: MediaDetail, addedFormat: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) })
        -> [(label: String, value: String)] {
        // The first audio stream, not index 0: a video's first stream is the picture.
        let streams = d.mediaSources?.first?.mediaStreams ?? d.mediaStreams ?? []
        let audio = streams.first { $0.type == "Audio" } ?? streams.first
        let source = d.mediaSources?.first
        let bitrate = audio?.bitRate ?? source?.bitrate
        let container = (source?.container ?? d.container)?.uppercased()
        let size = source?.size ?? d.size
        let artist = d.albumArtist ?? d.artists?.joined(separator: ", ")
        let ticks = d.runTimeTicks ?? 0

        var rows: [(String, String?)] = [
            ("Title", d.name),
            ("Artist", artist),
            ("Album", d.album),
            ("Year", d.productionYear.map(String.init)),
            ("Track", d.indexNumber.map(String.init)),
            ("Duration", clock(seconds: Double(ticks) / Double(Lyrics.ticksPerSecond))),
            ("Bitrate", bitrate.map { "\(Int((Double($0) / 1000).rounded())) kbps" } ?? "-"),
            ("Codec", audio?.codec?.uppercased() ?? "-"),
            ("Container", container ?? "-"),
            ("Sample rate", audio?.sampleRate.map { "\($0) Hz" } ?? "-"),
            ("Channels", audio?.channels.map(String.init)),
            ("Size", size.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "-"),
            ("Added", PlayHistory.date(d.dateCreated).map(addedFormat) ?? "-"),
            ("Played", (d.userData?.playCount ?? 0) > 0 ? "\(d.userData!.playCount!)\u{00D7}" : "Never"),
        ]
        rows.removeAll { ($0.1 ?? "").isEmpty }
        return rows.map { ($0.0, $0.1!) }
    }

    private static func clock(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Stream URL

/// The URL "Copy Stream URL" puts on the clipboard. Video and audio have
/// different routes: the desktop always built the Audio one, so a movie's
/// copied link did not play.
public func copyableStreamURL(config: ServerConfig, item: JfItem) -> URL? {
    let isVideo = item.type == "Movie" || item.type == "Episode" || item.mediaType == "Video"
    if isVideo {
        return URL(string: "\(config.url)/Videos/\(item.id)/stream?static=true&ApiKey=\(config.token)")
    }
    return universalStreamUrl(config: config, itemId: item.id)
}

// MARK: - Metadata edit

/// The eight fields of the metadata editor (metadata-editor.html), as the
/// text the form holds.
public struct MetadataFields: Equatable, Sendable {
    public var name = ""
    public var album = ""
    public var albumArtist = ""
    public var artists = ""
    public var genres = ""
    public var year = ""
    public var track = ""
    public var disc = ""

    public init() {}
}

/// An item's JSON as the server sent it, held as bytes so it can cross actors
/// (a [String: Any] cannot) and go back out with every key untouched.
public struct RawItem: Sendable {
    public let data: Data

    public init(data: Data) { self.data = data }

    public init(object: [String: Any]) throws {
        data = try JSONSerialization.data(withJSONObject: object)
    }

    public func object() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JellyfinError(status: 0, message: "The server sent an item this app cannot read")
        }
        return object
    }
}

public enum MetadataEdit {
    public struct NotANumber: LocalizedError {
        public let field: String
        public var errorDescription: String? { "\(field) must be a whole number." }
    }

    /// The form's starting values from the FULL item the server sent.
    public static func fields(from item: [String: Any]) -> MetadataFields {
        var f = MetadataFields()
        f.name = item["Name"] as? String ?? ""
        f.album = item["Album"] as? String ?? ""
        f.albumArtist = item["AlbumArtist"] as? String ?? ""
        f.artists = (item["Artists"] as? [String] ?? []).joined(separator: ", ")
        f.genres = (item["Genres"] as? [String] ?? []).joined(separator: ", ")
        f.year = (item["ProductionYear"] as? Int).map(String.init) ?? ""
        f.track = (item["IndexNumber"] as? Int).map(String.init) ?? ""
        f.disc = (item["ParentIndexNumber"] as? Int).map(String.init) ?? ""
        return f
    }

    /// Comma-separated text to a list: trimmed, empties dropped.
    public static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The whole fetched item with the eight fields replaced. Never a partial
    /// body: POST /Items/{id} blanks every field it is not sent, so the item
    /// goes back as it came with only these changed. An empty name keeps the
    /// old one; an empty year, track or disc clears it. Throws on a number
    /// field that is not a whole number rather than clearing it on a typo.
    public static func apply(_ f: MetadataFields, to item: [String: Any]) throws -> [String: Any] {
        func number(_ text: String, _ field: String) throws -> Any {
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return NSNull() }
            guard let n = Int(t) else { throw NotANumber(field: field) }
            return n
        }
        var out = item
        let name = f.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { out["Name"] = name }
        out["Album"] = f.album.trimmingCharacters(in: .whitespaces)
        out["AlbumArtist"] = f.albumArtist.trimmingCharacters(in: .whitespaces)
        out["Artists"] = list(f.artists)
        out["Genres"] = list(f.genres)
        out["ProductionYear"] = try number(f.year, "Year")
        out["IndexNumber"] = try number(f.track, "Track")
        out["ParentIndexNumber"] = try number(f.disc, "Disc")
        return out
    }
}

// MARK: - Client

public extension JellyfinClient {
    /// POST /Items/{id}/Refresh, the same elevated route as a library scan:
    /// an account without the right gets the server's 403 as a thrown error,
    /// where the desktop never read the status and reported "queued".
    func refreshMetadata(itemId: String) async throws {
        try await postRaw("/Items/\(itemId)/Refresh", body: Optional<EmptyBody>.none, params: [
            "metadataRefreshMode": "FullRefresh", "imageRefreshMode": "FullRefresh",
            "replaceAllMetadata": "false", "replaceAllImages": "false",
        ])
    }

    /// DELETE /Items/{id}: any item, a track or a whole playlist.
    func deleteItem(_ itemId: String) async throws {
        try await delete("/Items/\(itemId)")
    }

    func mediaDetail(itemId: String) async throws -> MediaDetail {
        try await get("/Users/\(currentConfig.userId)/Items/\(itemId)")
    }

    /// The item as the server holds it, for the metadata editor to change a
    /// few fields of and send back whole. Raw JSON rather than a JfItem,
    /// which models only a few fields and would drop the rest.
    func fullItem(itemId: String) async throws -> RawItem {
        let raw = RawItem(data: try await getData("/Items/\(itemId)", params: ["userId": currentConfig.userId]))
        _ = try raw.object()   // refuse anything that is not a JSON object here, not at save time
        return raw
    }

    /// POST /Items/{id} with a whole item. Built by hand (not postRaw) so the
    /// body's keys go out exactly as fetched, rather than through the PascalCase
    /// encoder's key rewriting, which would mangle map keys like ProviderIds.
    func updateItem(itemId: String, item: RawItem) async throws {
        let config = currentConfig
        guard let url = URL(string: "\(config.url)/Items/\(itemId)") else {
            throw JellyfinError(status: 0, message: "Bad URL for the item")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = item.data
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: data))
        }
    }

    /// The original file via /Items/{id}/Download (it honors the admin's
    /// download switch; /File does not), saved at `destination`. Moved into
    /// place only after a 2xx, so an error page never lands as a file.
    func downloadItem(itemId: String, to destination: URL) async throws {
        let config = currentConfig
        guard let url = URL(string: "\(config.url)/Items/\(itemId)/Download") else {
            throw JellyfinError(status: 0, message: "Bad download URL")
        }
        var request = URLRequest(url: url)
        request.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                         forHTTPHeaderField: "Authorization")
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: file, options: .mappedIfSafe)) ?? Data()
            throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: body.prefix(4096)))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
