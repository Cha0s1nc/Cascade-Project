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
    public static func resolve(client: JellyfinClient, config: ServerConfig, item: JfItem,
                               audioStreamIndex: Int? = nil, startTicks: Int = 0,
                               profile: DeviceProfile = .appleVideo) async throws -> ResolvedStream {
        struct Request: Encodable {
            var userId: String
            var maxStreamingBitrate: Int
            var deviceProfile: DeviceProfile
            var autoOpenLiveStream = true
            var startTimeTicks: Int?
            var mediaSourceId: String?
            var audioStreamIndex: Int?
        }
        let sourceId = item.mediaSources?.first?.id ?? item.id
        let info: PlaybackInfoResponse = try await client.post(
            "/Items/\(item.id)/PlaybackInfo",
            body: Request(userId: config.userId, maxStreamingBitrate: profile.maxStreamingBitrate ?? defaultMaxBitrate,
                          deviceProfile: profile, startTimeTicks: startTicks > 0 ? startTicks : nil,
                          mediaSourceId: sourceId, audioStreamIndex: audioStreamIndex),
            params: ["UserId": config.userId])
        guard let source = info.mediaSources?.first else {
            throw JellyfinError(status: 0, message: "The server offered no way to play this.")
        }
        if let transcodingUrl = source.transcodingUrl {
            guard let url = URL(string: withStartTicks(config.url + transcodingUrl, startTicks)) else {
                throw JellyfinError(status: 0, message: "Bad transcoding URL")
            }
            return ResolvedStream(url: url, playSessionId: info.playSessionId, mediaSourceId: source.id,
                                  direct: false, startTicks: startTicks)
        }
        guard source.supportsDirectPlay == true,
              let url = directUrl(config: config, itemId: item.id, source: source, playSessionId: info.playSessionId) else {
            throw JellyfinError(status: 0, message: "This video's format cannot play here, and the server offered no conversion.")
        }
        return ResolvedStream(url: url, playSessionId: info.playSessionId, mediaSourceId: source.id,
                              direct: true, startTicks: 0)
    }

    static func directUrl(config: ServerConfig, itemId: String, source: MediaSource, playSessionId: String?) -> URL? {
        let ext = source.container.map { ".\($0.split(separator: ",")[0])" } ?? ""
        guard var c = URLComponents(string: "\(config.url)/Videos/\(itemId)/stream\(ext)") else { return nil }
        c.queryItems = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "ApiKey", value: config.token)]
            + (source.id.map { [URLQueryItem(name: "mediaSourceId", value: $0)] } ?? [])
            + (playSessionId.map { [URLQueryItem(name: "PlaySessionId", value: $0)] } ?? [])
        return c.url
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
