import Foundation

/// Which family of Jellyfin stream endpoints an item uses. Movies and episodes
/// are both `.video`; music is `.audio`.
public enum MediaKind: String, Codable, Sendable {
    case audio = "Audio"
    case video = "Video"
}

public struct DirectPlayProfile: Codable, Sendable {
    public var type: MediaKind
    /// Comma-separated container list, e.g. "mp3,flac".
    public var container: String
    public var audioCodec: String?
    /// Video only. Comma-separated, e.g. "h264,vp9".
    public var videoCodec: String?

    public init(type: MediaKind, container: String, audioCodec: String? = nil, videoCodec: String? = nil) {
        self.type = type
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
    }
}

public struct TranscodingProfile: Codable, Sendable {
    public var type: MediaKind
    public var container: String
    public var audioCodec: String
    /// Encodes as "Protocol". Named around Swift refusing a member called
    /// `Protocol`; see JSON.swift for why every other field needs no such note.
    public var streamProtocol: String
    public var context: String?
    public var maxAudioChannels: String?
    public var videoCodec: String?

    enum CodingKeys: String, CodingKey {
        case type, container, audioCodec, context, maxAudioChannels, videoCodec
        case streamProtocol = "protocol"
    }

    public init(type: MediaKind, container: String, audioCodec: String, streamProtocol: String,
                context: String? = nil, maxAudioChannels: String? = nil, videoCodec: String? = nil) {
        self.type = type
        self.container = container
        self.audioCodec = audioCodec
        self.streamProtocol = streamProtocol
        self.context = context
        self.maxAudioChannels = maxAudioChannels
        self.videoCodec = videoCodec
    }
}

public struct SubtitleProfile: Codable, Sendable {
    public var format: String
    public var method: String
}

/// What this client tells the server it can decode.
///
/// The server trusts every claim in here, so a wrong one does not produce an
/// error: it produces a stream the device cannot decode, which sounds like
/// silence. Do not write a profile for hardware you do not have in hand.
public struct DeviceProfile: Codable, Sendable {
    public var name: String?
    public var maxStreamingBitrate: Int?
    public var directPlayProfiles: [DirectPlayProfile]
    public var transcodingProfiles: [TranscodingProfile]
    public var subtitleProfiles: [SubtitleProfile]

    public init(name: String? = nil, maxStreamingBitrate: Int? = nil,
                directPlayProfiles: [DirectPlayProfile], transcodingProfiles: [TranscodingProfile],
                subtitleProfiles: [SubtitleProfile] = []) {
        self.name = name
        self.maxStreamingBitrate = maxStreamingBitrate
        self.directPlayProfiles = directPlayProfiles
        self.transcodingProfiles = transcodingProfiles
        self.subtitleProfiles = subtitleProfiles
    }
}

// AVPlayer's audio floor, ported from the RN port's apple.ts. Every one of
// these is a codec Apple's own docs list as supported, not something inferred
// from Chromium or from Roku's device.
//
// Deliberately absent, with a reason for each:
//   - Opus: AVPlayer has no Opus decoder; claiming it direct-plays a file that
//     never makes sound.
//   - Vorbis: same story, no AVPlayer decoder.
//
// FLAC IS claimed, despite the platform notes calling ALAC the safer native
// choice: that is a preference between two supported codecs, not a warning.
// FLAC is supported on iOS/tvOS 11+ and a survey of the target server found
// 1087 of 1087 music tracks are FLAC, so omitting it would transcode the whole
// library on every play.
#if os(macOS)
let appleMaxBitrate = defaultMaxBitrate
#else
let appleMaxBitrate = 20_000_000
#endif

private let codecCheckedContainers = "aac,mp3,alac,m4a,flac"
private let codecCheckedAudioCodecs = "aac,mp3,alac,flac"

public extension DeviceProfile {
    /// The profile for Apple platforms (iOS, tvOS) playing through AVPlayer.
    ///
    /// maxStreamingBitrate is well under the desktop's 140 Mbps default on
    /// phones and set-top boxes: they are on Wi-Fi, and the desktop number is
    /// meaningless off a wired link. The Mac is the desktop, so its "Original"
    /// is the desktop's own: a hi-res FLAC runs past 20 Mbps and would be
    /// transcoded for rate under the phone's ceiling.
    static let apple = DeviceProfile(
        name: "Cascade Apple",
        maxStreamingBitrate: appleMaxBitrate,
        directPlayProfiles: [
            // audioCodec is spelled out rather than left to the container list
            // to imply, so a post-negotiation check has something concrete to
            // verify FLAC/AAC/MP3/ALAC against.
            DirectPlayProfile(type: .audio, container: codecCheckedContainers,
                              audioCodec: codecCheckedAudioCodecs),
            // WAV gets its own entry with no audioCodec: its codec is PCM under
            // one of several tag spellings Jellyfin reports (pcm_s16le and
            // friends), and guessing which one is exactly the kind of guess
            // that presents as silence. No audioCodec means "any codec in this
            // container", which for a WAV file is PCM anyway.
            DirectPlayProfile(type: .audio, container: "wav"),
        ],
        // HLS/AAC is what AVPlayer prefers.
        transcodingProfiles: [
            TranscodingProfile(type: .audio, container: "ts", audioCodec: "aac",
                               streamProtocol: "hls", context: "Streaming", maxAudioChannels: "2"),
        ],
        // Audio only for now. Video and subtitle profiles arrive with a video
        // port, not before.
        subtitleProfiles: []
    )

    /// The codecs this profile claims it can direct play, lowercased.
    var directPlayAudioCodecs: [String] {
        directPlayProfiles
            .filter { $0.type == .audio }
            .compactMap(\.audioCodec)
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
