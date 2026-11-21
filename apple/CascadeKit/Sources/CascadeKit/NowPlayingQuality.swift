import Foundation

/// The song's quality under its title in Now Playing, as (label, value) pairs: what is
/// in the file, or what the server converts it to when the stream is not the file
/// (AAC over HLS, at the streaming quality's bitrate). Flutter's qualityOf
/// (flutter/lib/core/playback.dart), with this app's transcode format.
public enum NowPlayingQuality {
    public static func of(_ detail: MediaDetail?, transcoding: Bool = false, transcodeBitrate: Int? = nil) -> [(label: String, value: String)] {
        guard let detail, let source = detail.mediaSources?.first else { return [] }
        let audio = (source.mediaStreams ?? detail.mediaStreams ?? []).first { $0.type == "Audio" }
        let codec = (audio?.codec ?? source.container?.split(separator: ",").first.map(String.init) ?? "").uppercased()
        if transcoding {
            return [("Format", "AAC")]
                + (transcodeBitrate.map { [("Bitrate", "\($0 / 1000) kbps")] } ?? [])
                + (codec.isEmpty ? [] : [("From", codec)])
        }
        var out: [(String, String)] = []
        if !codec.isEmpty { out.append(("Format", codec)) }
        if let depth = audio?.bitDepth, depth > 0 { out.append(("Bit depth", "\(depth)-bit")) }
        if let rate = audio?.sampleRate, rate > 0 {
            out.append(("Sample rate", rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)))
        }
        if let bits = audio?.bitRate ?? source.bitrate, bits > 0 { out.append(("Bitrate", "\(Int((Double(bits) / 1000).rounded())) kbps")) }
        return out
    }
}
