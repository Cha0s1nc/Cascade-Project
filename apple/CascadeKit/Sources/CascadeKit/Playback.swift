import Foundation

/// Ticks are Jellyfin's unit everywhere: 100 nanoseconds.
public let ticksPerSecond = 10_000_000.0

public func ticks(fromSeconds seconds: Double) -> Int {
    seconds <= 0 ? 0 : Int((seconds * ticksPerSecond).rounded())
}

public func seconds(fromTicks ticks: Int) -> Double {
    Double(ticks) / ticksPerSecond
}

/// Past this fraction of the runtime an item counts as finished rather than
/// in-progress. Jellyfin keeps a position on things played to the end, and
/// resuming ninety seconds before the outro is nobody's intent.
public let resumeCompleteRatio = 0.95

/// Where playback should pick up, in ticks. 0 means "start from the beginning".
public func resumeTicks(for item: JfItem?) -> Int {
    guard let ticks = item?.userData?.playbackPositionTicks, ticks > 0 else { return 0 }
    // Explicitly played: the position is a leftover, not an intent to resume.
    if item?.userData?.played == true { return 0 }
    if let total = item?.runTimeTicks, total > 0,
       Double(ticks) > Double(total) * resumeCompleteRatio { return 0 }
    return ticks
}

/// Put a start offset on a transcoding URL.
///
/// A progressive transcode is a body the server encodes as it sends, so the
/// player only ever knows about the part that has arrived and cannot seek past
/// it. Jellyfin's answer is a new stream that begins at the offset, which is
/// why seeking a transcode costs a request rather than a `seek` call.
///
/// Exported because seeking must not go back through PlaybackInfo: the URL the
/// first resolve handed over is still valid, and renegotiating to change one
/// number puts a whole round trip in front of every scrub.
public func withStartTicks(_ url: String, _ startTicks: Int) -> String {
    guard startTicks > 0, var components = URLComponents(string: url) else { return url }
    var items = (components.queryItems ?? []).filter { $0.name != "StartTimeTicks" }
    items.append(URLQueryItem(name: "StartTimeTicks", value: String(startTicks)))
    components.queryItems = items
    return components.url?.absoluteString ?? url
}

public struct ResolvedStream: Sendable, Equatable {
    public var url: URL
    /// Needed so playback reporting ties to the right server-side session.
    public var playSessionId: String?
    public var mediaSourceId: String?
    /// false when the server chose to transcode.
    public var direct: Bool
    /// Where this stream begins, in ticks. Non-zero only for a transcode asked
    /// to start partway in, because that is the one case where the player's own
    /// clock is measured from somewhere other than the start of the item. Add
    /// it to the player's time to get a real position.
    public var startTicks: Int
    /// What to report to /Sessions/Playing as PlayMethod.
    public var playMethod: PlayMethod { direct ? .directPlay : .transcode }
}

// MARK: - PlaybackInfo wire shapes

struct MediaSource: Decodable {
    var id: String?
    var container: String?
    var supportsDirectPlay: Bool?
    var supportsTranscoding: Bool?
    /// Server-relative when present; means "transcode, use this".
    var transcodingUrl: String?
    var mediaStreams: [JfMediaStream]?
}

struct PlaybackInfoResponse: Decodable {
    var mediaSources: [MediaSource]?
    var playSessionId: String?
}

struct PlaybackInfoRequest: Encodable {
    var userId: String
    var maxStreamingBitrate: Int
    var deviceProfile: DeviceProfile
    var autoOpenLiveStream: Bool
    var startTimeTicks: Int?
}

/// The desktop default, kept only for the `/universal` fallback URL which
/// predates profile negotiation.
public let defaultMaxBitrate = 140_000_000

/// The pre-negotiation stream URL, kept as a fallback.
///
/// If PlaybackInfo fails (older server, network blip, unexpected shape) this
/// still plays audio. `/universal` makes the server guess, which is what
/// Cascade did before profiles existed: acceptable as a degraded path, not as
/// the default. Opus and ogg are in this container list because it is the
/// server guessing rather than us claiming, and the server will transcode down
/// to something AVPlayer can take.
public func universalStreamUrl(config: ServerConfig, itemId: String,
                               maxBitrate: Int = defaultMaxBitrate) -> URL? {
    URL(string: "\(config.url)/Audio/\(itemId)/universal"
        + "?UserId=\(config.userId)&ApiKey=\(config.token)"
        + "&Container=mp3,aac,flac,wav,alac"
        + "&TranscodingContainer=ts&TranscodingProtocol=hls&AudioCodec=aac"
        + "&MaxStreamingBitrate=\(maxBitrate)")
}

/// Ask the server how to play an item, given what this client can decode.
///
/// Never throws: on any failure it falls back to `universalStreamUrl` so
/// playback degrades rather than dying.
public func resolveStream(client: JellyfinClient, config: ServerConfig, itemId: String,
                          profile: DeviceProfile = .apple,
                          startTicks: Int = 0) async -> ResolvedStream {
    let maxBitrate = profile.maxStreamingBitrate ?? defaultMaxBitrate
    do {
        let info: PlaybackInfoResponse = try await client.post(
            "/Items/\(itemId)/PlaybackInfo",
            body: PlaybackInfoRequest(
                userId: config.userId,
                maxStreamingBitrate: maxBitrate,
                deviceProfile: profile,
                autoOpenLiveStream: true,
                startTimeTicks: startTicks > 0 ? startTicks : nil
            ),
            // Also as a query param: 10.11 reads UserId from either, and the
            // body alone is not enough on some proxied setups.
            params: ["UserId": config.userId]
        )

        guard let source = info.mediaSources?.first else {
            throw JellyfinError(status: 0, message: "PlaybackInfo returned no media source")
        }

        if let transcodingUrl = source.transcodingUrl {
            let full = withStartTicks(config.url + transcodingUrl, startTicks)
            guard let url = URL(string: full) else {
                throw JellyfinError(status: 0, message: "Bad transcoding URL")
            }
            return ResolvedStream(url: url, playSessionId: info.playSessionId,
                                  mediaSourceId: source.id, direct: false, startTicks: startTicks)
        }

        guard let url = directStreamUrl(config: config, itemId: itemId, source: source,
                                        playSessionId: info.playSessionId) else {
            throw JellyfinError(status: 0, message: "Bad direct stream URL")
        }
        // Direct play hands over the whole file, so the player seeks inside it
        // on its own and the offset is never baked into the URL.
        return ResolvedStream(url: url, playSessionId: info.playSessionId,
                              mediaSourceId: source.id, direct: true, startTicks: 0)
    } catch {
        // The same cap as the negotiated request, so the fallback does not
        // quietly ignore the quality setting.
        guard let url = universalStreamUrl(config: config, itemId: itemId, maxBitrate: maxBitrate) else {
            // Nothing left to fall back to; the caller sees a URL it cannot use
            // rather than a crash.
            return ResolvedStream(url: URL(string: "about:blank")!, playSessionId: nil,
                                  mediaSourceId: nil, direct: false, startTicks: 0)
        }
        return ResolvedStream(url: url, playSessionId: nil, mediaSourceId: nil,
                              direct: false, startTicks: 0)
    }
}

func directStreamUrl(config: ServerConfig, itemId: String, source: MediaSource,
                     playSessionId: String?) -> URL? {
    // The container extension matters: without it some servers re-probe the
    // file on every request.
    let ext = source.container.map { ".\($0.split(separator: ",")[0])" } ?? ""
    guard var components = URLComponents(string: "\(config.url)/Audio/\(itemId)/stream\(ext)") else {
        return nil
    }
    var items = [URLQueryItem(name: "static", value: "true"),
                 URLQueryItem(name: "ApiKey", value: config.token)]
    if let id = source.id { items.append(URLQueryItem(name: "mediaSourceId", value: id)) }
    if let session = playSessionId { items.append(URLQueryItem(name: "PlaySessionId", value: session)) }
    components.queryItems = items
    return components.url
}

/// Tell the server to stop transcoding for a play session.
///
/// Abandoning a transcode is not free and the server will not always notice.
/// Pointing the player at a new offset leaves the previous ffmpeg running, and
/// with throttling off it keeps encoding at full speed for a file nobody is
/// listening to. A few scrubs is a few encoders competing for the same cores,
/// which looks exactly like "transcoding got slow" while being self-inflicted.
///
/// Best effort: a failure here costs CPU on the server, never correctness here.
public func stopActiveEncoding(client: JellyfinClient, config: ServerConfig,
                               playSessionId: String?) async {
    guard let playSessionId else { return }
    _ = try? await client.delete("/Videos/ActiveEncodings",
                                 params: ["deviceId": config.deviceId,
                                          "playSessionId": playSessionId])
}
