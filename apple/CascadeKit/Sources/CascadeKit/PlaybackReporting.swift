import Foundation

// Playback reporting: telling Jellyfin what this client is doing.
//
// Three endpoints - start, progress, stopped. The desktop app once called only
// start and stopped, which froze the server's view at the moment a track began:
// position never advanced, pause never registered, volume was never reported.
// A controller (the web UI, a phone) renders its transport from this state, so
// without progress reports its scrubber sits still.
//
// Progress must be sent periodically AND on every state change.

/// How often to check in while playing. Jellyfin's own clients use ~10s.
public let progressInterval: Duration = .seconds(10)

public enum PlayMethod: String, Codable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

/// A snapshot of local playback, in Jellyfin's units.
public struct PlaybackState: Sendable, Equatable {
    public var itemId: String
    /// 100ns units.
    public var positionTicks: Int
    public var isPaused: Bool
    public var isMuted: Bool
    /// 0-100, Jellyfin's scale, not the 0-1 AVPlayer uses.
    public var volumeLevel: Int
    public var playSessionId: String?
    public var mediaSourceId: String?
    public var playMethod: PlayMethod
    public var canSeek: Bool

    public init(itemId: String, positionTicks: Int, isPaused: Bool = false, isMuted: Bool = false,
                volumeLevel: Int = 100, playSessionId: String? = nil, mediaSourceId: String? = nil,
                playMethod: PlayMethod = .directPlay, canSeek: Bool = true) {
        self.itemId = itemId
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.isMuted = isMuted
        self.volumeLevel = volumeLevel
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.canSeek = canSeek
    }
}

/// The payload shared by start and progress.
///
/// VolumeLevel and IsMuted are the fields a controller binds its volume UI to;
/// omitting them is why remote volume once appeared to do nothing.
public struct PlaybackReport: Encodable, Sendable {
    public var itemId: String
    public var positionTicks: Int
    public var isPaused: Bool
    public var isMuted: Bool
    public var volumeLevel: Int
    public var canSeek: Bool
    public var playMethod: PlayMethod
    public var mediaType: String
    /// How a controller decides whether it may push a track at this session.
    public var queueableMediaTypes: [String]
    public var playSessionId: String?
    public var mediaSourceId: String?
    public var eventName: String?

    public init(_ s: PlaybackState, eventName: String? = nil) {
        itemId = s.itemId
        positionTicks = max(0, s.positionTicks)
        isPaused = s.isPaused
        isMuted = s.isMuted
        volumeLevel = min(100, max(0, s.volumeLevel))
        canSeek = s.canSeek
        playMethod = s.playMethod
        mediaType = "Audio"
        queueableMediaTypes = ["Audio"]
        playSessionId = s.playSessionId
        mediaSourceId = s.mediaSourceId
        self.eventName = eventName
    }
}

struct StoppedReport: Encodable {
    var itemId: String
    var positionTicks: Int
    var playSessionId: String?
    var mediaSourceId: String?
}

/// Reporting is best-effort: a dropped check-in must never interrupt playback,
/// and these fire on a timer where a thrown error would be noise. The next
/// check-in re-syncs.
public enum PlaybackReporter {
    public static func start(_ client: JellyfinClient, _ state: PlaybackState) async {
        _ = try? await client.postRaw("/Sessions/Playing", body: PlaybackReport(state))
    }

    public static func progress(_ client: JellyfinClient, _ state: PlaybackState) async {
        let event = state.isPaused ? "Pause" : "TimeUpdate"
        _ = try? await client.postRaw("/Sessions/Playing/Progress",
                                  body: PlaybackReport(state, eventName: event))
    }

    /// Playback ended. Drives play history, so position matters.
    public static func stopped(_ client: JellyfinClient, _ state: PlaybackState) async {
        _ = try? await client.postRaw("/Sessions/Playing/Stopped", body: StoppedReport(
            itemId: state.itemId,
            positionTicks: max(0, state.positionTicks),
            playSessionId: state.playSessionId,
            mediaSourceId: state.mediaSourceId
        ))
    }
}
