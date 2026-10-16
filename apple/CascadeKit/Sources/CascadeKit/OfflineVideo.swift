import Foundation

// Video downloads (docs/offline-mode-plan.md, section 6): which file to ask
// the server for, what it will do to make it, and whether what arrived is the
// whole film. The desktop's src/core/offline-video.ts, tested against the
// same fixture (test/fixtures/offline-video.json).
//
// Measured on jellyfin12 (12.2) before any of this was written:
// - A progressive transcode in Streaming context is a fragmented MP4. AVPlayer
//   seeks in it as fast as in an indexed MP4 (156 to 243 ms to playing), so it
//   is kept as it arrives; no AVAssetExportSession pass.
// - It is not throttled: a remux arrived at network speed, a 720p re-encode
//   at 32x realtime on the server's GPU.
// - It has no Content-Length, so the last fragment's time is what tells a
//   finished transcode from one that died partway.
// - Its HEVC is tagged hev1, which AVFoundation refuses ("Cannot Open");
//   hvc1RetagOffsets finds what to rewrite.

public enum VideoQuality: String, CaseIterable, Sendable {
    case original, p1080 = "1080p", p720 = "720p"

    /// A stored setting, read back: anything unknown is the platform default.
    public init(stored: String?, fallback: VideoQuality) {
        self = stored.flatMap(VideoQuality.init(rawValue:)) ?? fallback
    }

    public var height: Int? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        }
    }

    public var label: String { self == .original ? "Original" : rawValue }

    /// Original on the Mac, 1080p on the iPhone, for space (the maintainer's
    /// decision, 2026-10-14).
    public static var platformDefault: VideoQuality {
        #if os(macOS)
        .original
        #else
        .p1080
        #endif
    }
}

/// direct: the original file. remux: the server's MP4 with the video copied,
/// close to network speed. reencode: the video is encoded again, which takes
/// real time on the server.
public enum DownloadOutcome: String, Codable, Sendable {
    case direct, remux, reencode

    public var label: String {
        switch self {
        case .reencode: "Converting on the server"
        case .remux: "Downloading (repackaged by the server)"
        case .direct: "Downloading"
        }
    }
}

public enum OfflineVideo {
    /// A download is not a stream: no bitrate cap of its own, or Original
    /// would re-encode most Blu-ray files under the phone's 20 Mbps.
    public static let maxBitrate = 400_000_000

    /// Played this far, a video counts as watched: Jellyfin's own default.
    public static let watchedRatio = 0.9

    public static func isWatched(positionTicks: Int, runTimeTicks: Int?) -> Bool {
        guard let run = runTimeTicks, run > 0 else { return false }
        return Double(positionTicks) >= Double(run) * watchedRatio
    }

    /// The profile a download is negotiated with: AVPlayer's direct-play
    /// formats (the original file whenever it plays here), else one
    /// progressive MP4 with the video copied where it can be. The quality is
    /// a height condition on every codec, so the server decides; HEVC Main 10
    /// is claimed, or 10-bit HEVC re-encodes for nothing.
    public static func downloadProfile(_ quality: VideoQuality) -> DeviceProfile {
        let text = ["vtt", "webvtt", "srt", "subrip", "ass", "ssa", "ttml", "mov_text"]
        let pictures = ["pgssub", "dvdsub", "dvbsub"]
        var codecs = [CodecProfile(type: .video, codec: "hevc", conditions: [
            ProfileCondition(condition: "LessThanEqual", property: "VideoBitDepth", value: "10", isRequired: false),
            ProfileCondition(condition: "EqualsAny", property: "VideoProfile", value: "main|main 10", isRequired: false),
        ])]
        if let height = quality.height {
            codecs.append(CodecProfile(type: .video, conditions: [
                ProfileCondition(condition: "LessThanEqual", property: "Height", value: String(height), isRequired: true),
            ]))
        }
        return DeviceProfile(
            name: "Cascade Apple Download",
            maxStreamingBitrate: maxBitrate,
            directPlayProfiles: DeviceProfile.appleVideo.directPlayProfiles,
            transcodingProfiles: [
                TranscodingProfile(type: .video, container: "mp4", audioCodec: "aac,ac3,eac3", streamProtocol: "http",
                                   context: "Streaming", maxAudioChannels: "6", videoCodec: "h264,hevc"),
            ],
            subtitleProfiles: text.map { SubtitleProfile(format: $0, method: "External") }
                + pictures.map { SubtitleProfile(format: $0, method: "Encode") },
            codecProfiles: codecs)
    }

    /// The PlaybackInfo body. `burnIn` is a picture subtitle's stream index,
    /// which the server can only burn in.
    public struct Request: Encodable, Sendable {
        public var userId: String
        public var maxStreamingBitrate: Int
        public var deviceProfile: DeviceProfile
        public var autoOpenLiveStream = false
        public var subtitleStreamIndex: Int?

        public init(userId: String, profile: DeviceProfile, burnIn: Int?) {
            self.userId = userId
            maxStreamingBitrate = profile.maxStreamingBitrate ?? maxBitrate
            deviceProfile = profile
            subtitleStreamIndex = burnIn
        }
    }

    /// The parts of a PlaybackInfo answer a download reads.
    public struct Source: Decodable, Sendable {
        public struct Stream: Decodable, Sendable {
            public var type: String?
            public var index: Int?
            public var codec: String?
            public var language: String?
            public var displayTitle: String?
            public var isDefault: Bool?
            public var isForced: Bool?
            public var isTextSubtitleStream: Bool?
            public var width: Int?
            public var height: Int?
            public var bitRate: Int?
            public var bitDepth: Int?
            public var profile: String?
        }
        public var id: String?
        public var transcodingUrl: String?
        public var supportsDirectPlay: Bool?
        public var size: Int?
        public var mediaStreams: [Stream]?
    }

    public struct Info: Decodable, Sendable {
        public var mediaSources: [Source]?
        public var playSessionId: String?
    }

    private static func query(_ url: String) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(string: url)?.queryItems ?? [] { out[item.name.lowercased()] = item.value ?? "" }
        return out
    }

    /// What the server will do. TranscodeReasons cannot say it (an HEVC MKV
    /// reads VideoCodecNotSupported and is still copied); the server copies
    /// when the source fits what the URL allows, its CanStreamCopyVideo
    /// comparison, so that is what is compared. Checked against jellyfin12's
    /// own ffmpeg command for each fixture case.
    public static func outcome(_ source: Source) -> DownloadOutcome {
        guard let url = source.transcodingUrl else { return .direct }
        let q = query(url)
        if q["subtitlemethod"]?.lowercased() == "encode" { return .reencode }
        guard let video = source.mediaStreams?.first(where: { $0.type == "Video" }) else { return .remux }
        let codec = (video.codec ?? "").lowercased()
        let allowed = (q["videocodec"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard allowed.contains(codec) else { return .reencode }
        func over(_ key: String, _ value: Int?) -> Bool {
            guard let value, let limit = q[key].flatMap(Double.init) else { return false }
            return Double(value) > limit
        }
        if over("maxheight", video.height) || over("maxwidth", video.width) || over("videobitrate", video.bitRate)
            || over("\(codec)-videobitdepth", video.bitDepth) { return .reencode }
        if let profiles = q["\(codec)-profile"], !profiles.isEmpty, let p = video.profile?.lowercased(),
           !profiles.lowercased().split(whereSeparator: { $0 == "," || $0 == "|" }).map(String.init).contains(p) {
            return .reencode
        }
        return .remux
    }

    /// Roughly how big the file will be: the source's size for the original
    /// or a remux, the requested bitrates over the runtime for a re-encode.
    public static func estimatedBytes(_ outcome: DownloadOutcome, _ source: Source, runTimeTicks: Int?) -> Int? {
        guard outcome == .reencode else { return source.size.flatMap { $0 > 0 ? $0 : nil } }
        guard let url = source.transcodingUrl, let run = runTimeTicks, run > 0 else { return nil }
        let q = query(url)
        let bps = (q["videobitrate"].flatMap(Double.init) ?? 0) + (q["audiobitrate"].flatMap(Double.init) ?? 0)
        return bps > 0 ? Int((bps / 8 * Double(run) / 10_000_000).rounded()) : nil
    }

    /// Seconds left at the current rate, or nil when it cannot be guessed.
    public static func secondsLeft(received: Int, estimate: Int?, bytesPerSecond: Double) -> Int? {
        guard let estimate, estimate > 0, bytesPerSecond > 0, received < estimate else { return nil }
        return Int((Double(estimate - received) / bytesPerSecond).rounded())
    }

    // MARK: - Is the whole film there?

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }
    private static func u64(_ b: [UInt8], _ i: Int) -> Int { u32(b, i) << 32 | u32(b, i + 4) }
    private static func fourcc(_ b: [UInt8], _ i: Int) -> String { String(decoding: b[i..<i + 4], as: UTF8.self) }

    /// Boxes directly inside b[start..<end]: (type, payload start, box end).
    private static func children(_ b: [UInt8], _ start: Int, _ end: Int) -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = []
        var i = start
        while i + 8 <= end {
            var size = u32(b, i)
            var header = 8
            if size == 1, i + 16 <= end { size = u64(b, i + 8); header = 16 }
            guard size >= header, i + size <= end else { break }
            out.append((fourcc(b, i + 4), i + header, i + size))
            i += size
        }
        return out
    }

    /// Every whole top-level box's (type, offset, size), from headers only. A
    /// box that runs past the end of the file was cut off and ends the list.
    static func topLevel(read: (Int, Int) -> [UInt8], fileSize: Int) -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = []
        var i = 0
        while i + 8 <= fileSize {
            let h = read(i, 16)
            guard h.count >= 8 else { break }
            var size = u32(h, 0)
            if size == 1, h.count >= 16 { size = u64(h, 8) } else if size == 0 { size = fileSize - i }
            guard size >= 8, i + size <= fileSize else { break }
            out.append((fourcc(h, 4), i, size))
            i += size
        }
        return out
    }

    /// Where a fragmented MP4's last whole fragment ends, in seconds, or nil
    /// when it is not one. A transcode cut off partway reads that much
    /// shorter (674 s truncated read as 395 s in AVFoundation and ffprobe).
    public static func fragmentedEndSeconds(read: (Int, Int) -> [UInt8], fileSize: Int) -> Double? {
        let boxes = topLevel(read: read, fileSize: fileSize)
        // A fragment counts once its samples (the mdat after it) are all there.
        let moofs = boxes.indices.filter { boxes[$0].0 == "moof" && $0 + 1 < boxes.count && boxes[$0 + 1].0 == "mdat" }
        guard let moovBox = boxes.first(where: { $0.0 == "moov" }), let last = moofs.last else { return nil }
        let moov = read(moovBox.1, moovBox.2)
        var timescale: [Int: Int] = [:]
        var defaultDuration: [Int: Int] = [:]
        for (t, s, e) in children(moov, 8, moov.count) {
            if t == "trak" {
                var id = 0, scale = 0
                for (tt, ts, te) in children(moov, s, e) {
                    if tt == "tkhd" { id = moov[ts] == 1 ? u32(moov, ts + 20) : u32(moov, ts + 12) }
                    if tt == "mdia" {
                        for (mt, ms, _) in children(moov, ts, te) where mt == "mdhd" {
                            scale = moov[ms] == 1 ? u32(moov, ms + 20) : u32(moov, ms + 12)
                        }
                    }
                }
                if id != 0, scale != 0 { timescale[id] = scale }
            }
            if t == "mvex" {
                for (xt, xs, _) in children(moov, s, e) where xt == "trex" { defaultDuration[u32(moov, xs + 4)] = u32(moov, xs + 12) }
            }
        }
        let moof = read(boxes[last].1, boxes[last].2)
        var end: Double?
        for (t, s, e) in children(moof, 8, moof.count) where t == "traf" {
            var track = 0, base = 0, dflt = 0, total = 0
            for (ft, fs, _) in children(moof, s, e) {
                if ft == "tfhd" {
                    let flags = u32(moof, fs) & 0xffffff
                    track = u32(moof, fs + 4)
                    dflt = defaultDuration[track] ?? 0
                    var p = fs + 8
                    if flags & 0x01 != 0 { p += 8 }
                    if flags & 0x02 != 0 { p += 4 }
                    if flags & 0x08 != 0 { dflt = u32(moof, p) }
                } else if ft == "tfdt" {
                    base = moof[fs] == 1 ? u64(moof, fs + 4) : u32(moof, fs + 4)
                } else if ft == "trun" {
                    let flags = u32(moof, fs) & 0xffffff
                    let count = u32(moof, fs + 4)
                    var p = fs + 8 + (flags & 0x01 != 0 ? 4 : 0) + (flags & 0x04 != 0 ? 4 : 0)
                    let per = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }.count * 4
                    if flags & 0x100 != 0 {
                        for _ in 0..<count { total += u32(moof, p); p += per }
                    } else {
                        total += count * dflt
                    }
                }
            }
            if let scale = timescale[track] { end = max(end ?? 0, Double(base + total) / Double(scale)) }
        }
        return end
    }

    /// How far short of the runtime a transcode may end and still be whole.
    public static let truncationToleranceSeconds = 15.0

    /// Whether a transcode that ended at `endSeconds` holds the whole item.
    /// A progressive transcode is always fragmented: no fragment at all is a
    /// stream cut off before its first. An unknown runtime is not judged.
    public static func isWholeTranscode(endSeconds: Double?, runTimeTicks: Int?) -> Bool {
        guard let run = runTimeTicks, run > 0 else { return true }
        guard let endSeconds else { return false }
        return endSeconds >= Double(run) / 10_000_000 - truncationToleranceSeconds
    }

    /// Offsets in the file of each `hev1` sample entry in the moov, to be
    /// rewritten as `hvc1`: the same four bytes ffmpeg's `-tag:v hvc1`
    /// changes. Jellyfin adds that tag to its HLS output only, and AVFoundation
    /// will not open HEVC tagged hev1. The parameter sets are in the hvcC box
    /// either way (ffmpeg writes them from the source's extradata).
    public static func hvc1RetagOffsets(read: (Int, Int) -> [UInt8], fileSize: Int) -> [Int] {
        guard let moovBox = topLevel(read: read, fileSize: fileSize).first(where: { $0.0 == "moov" }) else { return [] }
        let moov = read(moovBox.1, moovBox.2)
        var out: [Int] = []
        func walk(_ start: Int, _ end: Int) {
            for (t, s, e) in children(moov, start, end) {
                switch t {
                case "trak", "mdia", "minf", "stbl": walk(s, e)
                case "stsd":
                    // Full box (4 bytes), entry count (4), then the entries.
                    for (entry, es, _) in children(moov, s + 8, e) where entry == "hev1" { out.append(moovBox.1 + es - 4) }
                default: break
                }
            }
        }
        walk(8, moov.count)
        return out
    }
}

// MARK: - New episodes, watched ones, and placement

public extension OfflineIndex {
    /// Most episode ids a followed series remembers as removed.
    static let maxSkippedEpisodes = 5000
    /// A watched episode is removed this long after it was finished.
    static let removeWatchedAfter: TimeInterval = 24 * 60 * 60

    mutating func markWatched(_ trackId: String, now: Date) {
        if tracks[trackId] != nil { tracks[trackId]?.watchedAt = now }
    }

    mutating func setOutcome(_ trackId: String, _ outcome: DownloadOutcome) {
        if tracks[trackId] != nil { tracks[trackId]?.outcome = outcome }
    }

    mutating func setBurnIn(_ trackId: String, _ streamIndex: Int?) {
        guard tracks[trackId] != nil else { return }
        tracks[trackId]?.burnIn = streamIndex.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Turns "Download new episodes as they arrive" on or off for a
    /// downloaded series. On counts from now: what the server had already
    /// came with the series.
    mutating func setFollow(_ seriesId: String, on: Bool, now: Date) {
        guard let i = collections.firstIndex(where: { $0.id == seriesId }), collections[i].item.type == "Series" else { return }
        if on { if collections[i].follow == nil { collections[i].follow = now } } else { collections[i].follow = nil }
    }

    /// The episodes a followed series should fetch now, from the server's
    /// list: added after the follow started, not already held, not watched,
    /// and not one removed as watched. Empty when not followed.
    func newEpisodes(_ seriesId: String, from episodes: [JfItem]) -> [JfItem] {
        guard let c = collection(seriesId), let since = c.follow else { return [] }
        let held = Set(c.trackIds)
        let skip = Set(c.skip ?? [])
        return episodes.filter { e in
            guard Self.isSafeId(e.id), e.type == "Episode", !held.contains(e.id), !skip.contains(e.id),
                  e.userData?.played != true, let created = e.dateCreated.flatMap(Self.parseDate) else { return false }
            return created > since
        }
    }

    /// Adds items to a collection already asked for, after the ones it has.
    mutating func addToCollection(_ collectionId: String, _ items: [JfItem]) {
        guard let i = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        for t in items where Self.isSafeId(t.id) && (t.type == nil || Self.mediaTypes.contains(t.type!))
            && !collections[i].trackIds.contains(t.id) {
            collections[i].trackIds.append(t.id)
            if tracks[t.id] == nil { tracks[t.id] = Track(item: Self.slimmed(t)) }
        }
    }

    /// Downloaded episodes finished at least a day ago: played to the end on
    /// this device, or marked played on the server after the file landed.
    /// Movies are never removed.
    func watchedToRemove(now: Date) -> [String] {
        tracks.compactMap { id, t -> String? in
            guard t.item.type == "Episode", t.file != nil else { return nil }
            var finished = t.watchedAt
            if finished == nil, t.item.userData?.played == true, let readyAt = t.readyAt,
               let played = t.item.userData?.lastPlayedDate.flatMap(Self.parseDate), played > readyAt {
                finished = played
            }
            guard let finished, now.timeIntervalSince(finished) >= Self.removeWatchedAfter else { return nil }
            return id
        }.sorted()
    }

    /// Removes single items (watched episodes) from every collection holding
    /// them. A followed series remembers them and stays even when empty, to
    /// receive new ones; any other collection left empty goes. Returns the
    /// files now nobody's.
    @discardableResult
    mutating func removeTracks(_ ids: [String]) -> [String] {
        let drop = Set(ids)
        for i in collections.indices {
            let removed = collections[i].trackIds.filter(drop.contains)
            guard !removed.isEmpty else { continue }
            collections[i].trackIds.removeAll(where: drop.contains)
            if collections[i].follow != nil {
                collections[i].skip = Array(((collections[i].skip ?? []) + removed).suffix(Self.maxSkippedEpisodes))
            }
        }
        collections.removeAll { $0.trackIds.isEmpty && $0.follow == nil }
        let kept = Set(collections.flatMap(\.trackIds))
        var orphaned: [String] = []
        for (id, track) in tracks where !kept.contains(id) {
            if let file = track.file { orphaned.append(file) }
            orphaned += (track.subs ?? []).map(\.file)
            tracks[id] = nil
        }
        containers = containers.filter { key, _ in tracks.values.contains { $0.item.seriesId == key || $0.item.seasonId == key } }
        return orphaned.sorted()
    }

    /// Unplaced items grouped by what they share a library with: a track by
    /// its album, an episode by its show, anything else by itself. Each
    /// group's library is one /Items/{id}/Ancestors request. Not Ids with
    /// ParentId, which this was first built on: Jellyfin 12.2 ignores ParentId
    /// when Ids is given (checked on jellyfin12), which put every download in
    /// whichever library was asked last.
    func placementGroups(_ trackIds: [String]) -> [(group: String, ids: [String])] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for id in trackIds {
            guard let item = tracks[id]?.item else { continue }
            let key = [item.albumId, item.seriesId, id].compactMap { $0 }.first(where: Self.isSafeId) ?? id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(id)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// The stored library among an item's ancestors, nearest first.
    func library(amongAncestors ancestors: [JfItem]) -> String? {
        let stored = Set(libraries.map(\.id))
        return ancestors.first { stored.contains($0.id) }?.id
    }

    /// Jellyfin's dates, with up to seven fractional digits.
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed.hasSuffix("Z") || trimmed.contains("+") ? trimmed : trimmed + "Z")
    }
}
