import Foundation

// Internet radio, played through Jellyfin's Live TV channel pipeline: the
// desktop's src/core/radio.ts.
//
// Why Live TV and not a .strm file in a music library: a .strm in a music
// library scans as an Audio item, and Jellyfin only swaps a .strm's path for
// the URL inside it for a Video entity, so streaming it hands ffmpeg the text
// file itself (HTTP 500, "FFmpeg exited with code 183"). A Live TV channel
// from an M3U tuner has none of that problem: PlaybackInfo resolves it to
// Protocol=Http with IsInfiniteStream=true and a working LiveStreamId, and
// /Audio/{channelId}/stream returns real audio.
//
// What Jellyfin does NOT do is say which channels are radio and which are TV:
// an M3U tuner's channels always come back ChannelType=TV, and the server's
// own type=Radio filter on /LiveTv/Channels is a no-op. So radio is opt-in
// (the `cascade.radioEnabled` setting), not detected.

/// The setting that turns the Radio section on, once the person confirms
/// their server's Live TV channels are radio. The desktop's `radioEnabled`.
public let radioEnabledKey = "cascade.radioEnabled"

/// A Live TV channel is the one kind of item this feature ever hands to the
/// player, so the type alone is a reliable "is this radio" guard wherever one
/// is needed, whatever the Radio view did to decide what to list.
public func isRadioItem(_ item: JfItem?) -> Bool {
    item?.type == "TvChannel"
}

/// The pieces of a resolved Live TV media source the stream URL needs.
public struct RadioSource: Sendable, Equatable {
    public var id: String?
    public var container: String?
    public var liveStreamId: String?

    public init(id: String? = nil, container: String? = nil, liveStreamId: String? = nil) {
        self.id = id
        self.container = container
        self.liveStreamId = liveStreamId
    }
}

public struct ResolvedRadioStream: Sendable, Equatable {
    public var url: URL
    public var playSessionId: String?
    public var mediaSourceId: String?
    /// The open tuner session on the server. Must be closed when the station
    /// is left, or the server keeps its ffmpeg running for nobody.
    public var liveStreamId: String?
}

/// The URL a resolved channel plays through: the plain /Audio/{id}/stream
/// endpoint, as for a track, carrying LiveStreamId so the server knows which
/// open session to read. Never `static=true`: that means "hand over the file
/// byte for byte", which for a remote channel is the wrong request entirely.
/// Omitting it is what makes the server relay the live source.
public func buildRadioStreamUrl(config: ServerConfig, channelId: String,
                                source: RadioSource, playSessionId: String?) -> URL? {
    var items = [URLQueryItem(name: "ApiKey", value: config.token)]
    if let id = source.id, !id.isEmpty { items.append(URLQueryItem(name: "mediaSourceId", value: id)) }
    if let live = source.liveStreamId, !live.isEmpty { items.append(URLQueryItem(name: "LiveStreamId", value: live)) }
    if let session = playSessionId, !session.isEmpty { items.append(URLQueryItem(name: "PlaySessionId", value: session)) }
    let ext = source.container.flatMap { $0.split(separator: ",").first }.map { ".\($0)" } ?? ""
    guard var components = URLComponents(string: "\(config.url)/Audio/\(channelId)/stream\(ext)") else { return nil }
    components.queryItems = items
    return components.url
}

// MARK: - Wire shapes
//
// Their own, rather than Playback.swift's: that file's MediaSource has no
// LiveStreamId, and its direct play / transcode branching assumes a finite
// item.

private struct RadioMediaSource: Decodable {
    var id: String?
    var container: String?
    var liveStreamId: String?
}

private struct RadioPlaybackInfo: Decodable {
    var mediaSources: [RadioMediaSource]?
    var playSessionId: String?
}

private struct RadioPlaybackRequest: Encodable {
    var userId: String
    var maxStreamingBitrate: Int
    var deviceProfile: DeviceProfile
    var autoOpenLiveStream: Bool
}

private struct UserPolicyEnvelope: Decodable {
    struct Policy: Decodable { var enableLiveTvAccess: Bool? }
    var policy: Policy?
}

public extension JellyfinClient {
    /// Asks the server to open and describe a channel's stream. Separate from
    /// `resolveStream` for the reason above: a channel has no TranscodingUrl,
    /// and AutoOpenLiveStream is what matters. Throws, unlike resolveStream,
    /// because there is no universal URL to fall back to for a channel.
    func resolveRadioStream(channelId: String, profile: DeviceProfile, maxBitrate: Int) async throws -> ResolvedRadioStream {
        let config = currentConfig
        var profile = profile
        profile.maxStreamingBitrate = maxBitrate
        let info: RadioPlaybackInfo = try await post(
            "/Items/\(channelId)/PlaybackInfo",
            body: RadioPlaybackRequest(userId: config.userId, maxStreamingBitrate: maxBitrate,
                                       deviceProfile: profile, autoOpenLiveStream: true),
            params: ["UserId": config.userId])
        guard let source = info.mediaSources?.first else {
            throw JellyfinError(status: 0, message: "PlaybackInfo returned no media source for this channel")
        }
        let radioSource = RadioSource(id: source.id, container: source.container, liveStreamId: source.liveStreamId)
        guard let url = buildRadioStreamUrl(config: config, channelId: channelId, source: radioSource,
                                            playSessionId: info.playSessionId) else {
            throw JellyfinError(status: 0, message: "Bad radio stream URL")
        }
        return ResolvedRadioStream(url: url, playSessionId: info.playSessionId,
                                   mediaSourceId: source.id, liveStreamId: source.liveStreamId)
    }

    /// Releases the server's tuner/ffmpeg session behind a channel. Best
    /// effort and never throws, like stopActiveEncoding: the caller is always
    /// mid-teardown, and a failure costs the server a lingering process, never
    /// correctness here.
    func closeRadioStream(liveStreamId: String?) async {
        guard let liveStreamId, !liveStreamId.isEmpty else { return }
        _ = try? await postRaw("/LiveStreams/Close", body: String?.none, params: ["liveStreamId": liveStreamId])
    }

    /// The server's Live TV channels. Whether they are radio is the person's
    /// call (see the file header).
    func radioChannels() async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/LiveTv/Channels", params: [
            "userId": currentConfig.userId, "enableImages": "true",
        ])
        return response.items ?? []
    }

    /// Whether this account may use Live TV at all (its policy), which the
    /// Radio section and its setting are gated on: an account without it
    /// would otherwise get a section that 403s.
    func hasLiveTvAccess() async throws -> Bool {
        let user: UserPolicyEnvelope = try await get("/Users/\(currentConfig.userId)")
        return user.policy?.enableLiveTvAccess == true
    }
}
