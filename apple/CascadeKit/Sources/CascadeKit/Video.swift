import Foundation

// Movies and shows: what to ask the server for, and how to play one. The
// desktop's video half (openMovie, openSeries, playVideo in renderer.js),
// with Apple's own player doing the drawing.

public extension DeviceProfile {
    /// Video through AVPlayer, from Apple's documented formats only.
    ///
    /// Direct play is MP4/MOV with H.264 or HEVC (every device iOS 18 runs on
    /// decodes both). Anything else (MKV, most of a typical library) comes as
    /// HLS, remuxed when the codecs already fit, with text subtitles in the
    /// manifest so AVPlayer's own menu offers them, and picture subtitles
    /// (PGS, VobSub) burned in, since AVPlayer cannot draw them.
    static let appleVideo = DeviceProfile(
        name: "Cascade Apple Video",
        maxStreamingBitrate: 20_000_000,
        directPlayProfiles: [
            DirectPlayProfile(type: .video, container: "mp4,m4v,mov",
                              audioCodec: "aac,ac3,eac3,mp3", videoCodec: "h264,hevc"),
        ],
        transcodingProfiles: [
            TranscodingProfile(type: .video, container: "ts", audioCodec: "aac,ac3,eac3",
                               streamProtocol: "hls", context: "Streaming", maxAudioChannels: "6",
                               videoCodec: "h264"),
        ],
        subtitleProfiles: videoSubtitleProfiles
    )
}

private let videoSubtitleProfiles: [SubtitleProfile] = {
    let text = ["vtt", "webvtt", "srt", "subrip", "ass", "ssa", "ttml", "mov_text"]
    let pictures = ["pgssub", "dvdsub", "dvbsub"]
    return text.map { SubtitleProfile(format: $0, method: "Hls") }
        + pictures.map { SubtitleProfile(format: $0, method: "Encode") }
}()

/// Fields a video list asks for.
private let videoFields = "Overview,ProductionYear,OfficialRating,CommunityRating,BackdropImageTags,SeriesId,SeasonId,MediaStreams,MediaSources"

public extension JellyfinClient {
    func movies(sortBy: String = "SortName", sortOrder: String = "Ascending") async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/Items", params: [
            "userId": currentConfig.userId, "includeItemTypes": "Movie", "recursive": "true",
            "sortBy": sortBy, "sortOrder": sortOrder, "fields": videoFields,
        ])
        return r.items ?? []
    }

    func shows() async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/Items", params: [
            "userId": currentConfig.userId, "includeItemTypes": "Series", "recursive": "true",
            "sortBy": "SortName", "fields": videoFields,
        ])
        return r.items ?? []
    }

    func seasons(of seriesId: String) async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/Shows/\(seriesId)/Seasons", params: [
            "userId": currentConfig.userId,
        ])
        return r.items ?? []
    }

    /// A season's episodes, or the whole show's with no season.
    func episodes(of seriesId: String, season: String? = nil) async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/Shows/\(seriesId)/Episodes", params: [
            "userId": currentConfig.userId, "seasonId": season, "fields": videoFields,
        ])
        return r.items ?? []
    }

    /// Movies, shows and episodes matching a search: the Video mode's search
    /// screen. Empty for a blank term.
    func searchVideo(_ term: String, limit: Int = 60) async throws -> [JfItem] {
        guard let params = VideoPlayback.searchParams(term: term, userId: currentConfig.userId, limit: limit) else { return [] }
        let r: JfItemsResponse = try await get("/Items", params: params)
        return r.items ?? []
    }

    /// Next episode to watch, per show (or for one show).
    func nextUp(seriesId: String? = nil, limit: Int = 20) async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/Shows/NextUp", params: [
            "userId": currentConfig.userId, "seriesId": seriesId, "limit": String(limit),
            "fields": videoFields,
        ])
        return r.items ?? []
    }

    /// Movies and episodes started and not finished.
    func continueWatching(limit: Int = 20) async throws -> [JfItem] {
        let r: JfItemsResponse = try await get("/UserItems/Resume", params: [
            "userId": currentConfig.userId, "mediaTypes": "Video", "limit": String(limit),
            "fields": videoFields,
        ])
        return r.items ?? []
    }

    /// Recently added, of one type ("Movie" or "Episode").
    func latestVideo(_ type: String, limit: Int = 20) async throws -> [JfItem] {
        let items: [JfItem] = try await get("/Items/Latest", params: [
            "userId": currentConfig.userId, "includeItemTypes": type, "limit": String(limit),
            "fields": videoFields, "groupItems": "false",
        ])
        return items
    }
}

public enum VideoPlayback {
    /// The request with the choices a person can make before playing. The
    /// server honors an audio track only alongside the media source id
    /// (checked on 10.11.11), and the transcode then carries that track alone.
    ///
    /// No start position goes to the server: a resume is a seek once the
    /// stream has loaded. Jellyfin's HLS playlist always covers the whole film,
    /// so a transcode asked to start partway (StartTimeTicks) left AVPlayer
    /// asking for segments from the top, which the server answered with 400:
    /// every resume of a transcoded film failed. Seeking in that playlist is
    /// what scrubbing already does, and it works anywhere in the film.
    public static func resolve(client: JellyfinClient, config: ServerConfig, item: JfItem,
                               audioStreamIndex: Int? = nil,
                               profile: DeviceProfile = .appleVideo) async throws -> ResolvedStream {
        struct Request: Encodable {
            var userId: String
            var maxStreamingBitrate: Int
            var deviceProfile: DeviceProfile
            var autoOpenLiveStream = true
            var mediaSourceId: String?
            var audioStreamIndex: Int?
        }
        let sourceId = item.mediaSources?.first?.id ?? item.id
        let info: PlaybackInfoResponse = try await client.post(
            "/Items/\(item.id)/PlaybackInfo",
            body: Request(userId: config.userId, maxStreamingBitrate: profile.maxStreamingBitrate ?? defaultMaxBitrate,
                          deviceProfile: profile, mediaSourceId: sourceId, audioStreamIndex: audioStreamIndex),
            params: ["UserId": config.userId])
        guard let source = info.mediaSources?.first else {
            throw JellyfinError(status: 0, message: "The server offered no way to play this.")
        }
        if let transcodingUrl = source.transcodingUrl {
            guard let url = transcodeURL(config.url + transcodingUrl) else {
                throw JellyfinError(status: 0, message: "Bad transcoding URL")
            }
            return ResolvedStream(url: url, playSessionId: info.playSessionId, mediaSourceId: source.id,
                                  direct: false, startTicks: 0)
        }
        guard source.supportsDirectPlay == true,
              let url = directUrl(config: config, itemId: item.id, source: source, playSessionId: info.playSessionId) else {
            throw JellyfinError(status: 0, message: "This video's format cannot play here, and the server offered no conversion.")
        }
        return ResolvedStream(url: url, playSessionId: info.playSessionId, mediaSourceId: source.id,
                              direct: true, startTicks: 0)
    }

    /// The server's transcode URL with any start position taken off, so the
    /// stream is the whole film (see resolve), and, for HLS, asking for every
    /// text subtitle in the manifest. Jellyfin lists them only when a subtitle
    /// was chosen up front or this flag is set (DynamicHlsHelper, 10.11), so
    /// without it a film had no captions to pick from.
    static func transcodeURL(_ url: String) -> URL? {
        guard var c = URLComponents(string: url) else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name.caseInsensitiveCompare("StartTimeTicks") != .orderedSame }
        if c.path.lowercased().hasSuffix(".m3u8"),
           !items.contains(where: { $0.name.caseInsensitiveCompare("EnableSubtitlesInManifest") == .orderedSame }) {
            items.append(URLQueryItem(name: "EnableSubtitlesInManifest", value: "true"))
        }
        c.queryItems = items.isEmpty ? nil : items
        return c.url
    }

    static func directUrl(config: ServerConfig, itemId: String, source: MediaSource, playSessionId: String?) -> URL? {
        let ext = source.container.map { ".\($0.split(separator: ",")[0])" } ?? ""
        guard var c = URLComponents(string: "\(config.url)/Videos/\(itemId)/stream\(ext)") else { return nil }
        c.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: config.token)]
            + (source.id.map { [URLQueryItem(name: "mediaSourceId", value: $0)] } ?? [])
            + (playSessionId.map { [URLQueryItem(name: "PlaySessionId", value: $0)] } ?? [])
        return c.url
    }

    /// The query behind searchVideo, nil for a blank term. Fields as the video
    /// lists ask for them, so a result opens a detail page or plays as one.
    public static func searchParams(term: String, userId: String, limit: Int = 60) -> [String: String?]? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ["userId": userId, "searchTerm": trimmed, "includeItemTypes": "Movie,Series,Episode",
                "recursive": "true", "fields": videoFields, "limit": String(limit)]
    }

    /// "S1:E2" for an episode, as the desktop's episodeCode.
    public static func episodeCode(_ item: JfItem) -> String? {
        guard item.type == "Episode", let e = item.indexNumber else { return nil }
        return item.parentIndexNumber.map { "S\($0):E\(e)" } ?? "E\(e)"
    }

    /// The audio tracks a person can pick from, with the default first.
    public static func audioTracks(_ item: JfItem) -> [JfMediaStream] {
        (item.mediaStreams ?? []).filter { $0.type == "Audio" && $0.index != nil }
    }
}

/// What a subtitle or audio menu calls a track. The stream's own name is the
/// server's ("English Signs - ASS", "For ENG Dub - English - SUBRIP"), where
/// the system's display name is only the language, so five English tracks
/// would read the same. The codec on the end means nothing to a viewer.
public func mediaTrackLabel(playlistName: String?, fallback: String) -> String {
    guard var parts = playlistName?.components(separatedBy: " - ").map({ $0.trimmingCharacters(in: .whitespaces) })
        .filter({ !$0.isEmpty }), !parts.isEmpty else { return fallback }
    if parts.count > 1, let last = parts.last, last.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
        parts.removeLast()
    }
    return parts.joined(separator: " - ")
}
