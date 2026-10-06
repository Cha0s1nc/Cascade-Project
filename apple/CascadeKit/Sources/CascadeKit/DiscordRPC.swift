import Foundation

// The pure half of Discord Rich Presence (main.js ~139-255): frames, activity JSON, timing.
// The socket and the app wiring live in App/Mac/DiscordRPC.swift.

public enum DiscordOp: UInt32, Sendable { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }

public struct DiscordActivity: Equatable, Sendable {
    public var details: String
    public var state: String
    /// Discord's type 3 ("Watching") instead of type 2 ("Listening").
    public var watching: Bool
    public var startMs: Int?
    public var endMs: Int?
    public var largeImage: String?
    public var largeText: String?

    public init(details: String, state: String, watching: Bool, startMs: Int? = nil, endMs: Int? = nil,
                largeImage: String? = nil, largeText: String? = nil) {
        self.details = details; self.state = state; self.watching = watching
        self.startMs = startMs; self.endMs = endMs; self.largeImage = largeImage; self.largeText = largeText
    }

    /// Discord's ActivityType: 2 Listening, 3 Watching. status_display_type 1 shows the state
    /// (artist or series) in the member list sidebar.
    var json: [String: Any] {
        var a: [String: Any] = ["details": String(details.prefix(128)), "type": watching ? 3 : 2,
                                "status_display_type": 1, "instance": false]
        // An empty string is not a valid state, so a movie with no year just has none.
        if !state.isEmpty { a["state"] = String(state.prefix(128)) }
        var ts: [String: Any] = [:]
        if let startMs { ts["start"] = startMs }
        if let endMs { ts["end"] = endMs }
        if !ts.isEmpty { a["timestamps"] = ts }
        var assets: [String: Any] = [:]
        if let largeImage { assets["large_image"] = largeImage }
        if let largeText { assets["large_text"] = String(largeText.prefix(128)) }
        if !assets.isEmpty { a["assets"] = assets }
        return a
    }

    /// What a track or video becomes on the profile. Discord draws its progress bar only when
    /// the activity carries both timestamps. `startMs` is the wall-clock instant the head would
    /// have been at zero, so seeks and resumes just re-anchor it.
    public static func make(item: JfItem, startMs: Int, fallbackDurationMs: Double?) -> DiscordActivity {
        let video = item.type == "Movie" || item.type == "Episode" || item.mediaType == "Video"
        let state: String
        switch item.type {
        case "Episode":
            var code = ""
            if let s = item.parentIndexNumber, let e = item.indexNumber { code = "S\(s):E\(e)" }
            state = [item.seriesName ?? "", code].filter { !$0.isEmpty }.joined(separator: " \u{B7} ")
        case "Movie": state = item.productionYear.map(String.init) ?? ""
        default: state = item.albumArtist ?? item.artists?.first ?? "Unknown Artist"
        }
        // Jellyfin's runtime is known before the media loads; a transcode's own duration only
        // counts what has been encoded so far.
        let dur = item.runTimeTicks.map { Double($0) / 10_000 } ?? fallbackDurationMs
        var a = DiscordActivity(details: item.name ?? "Unknown Track", state: state, watching: video, startMs: startMs)
        if let d = dur, d.isFinite, d > 0 { a.endMs = startMs + Int(d.rounded()) }
        if !video, let album = item.album, !album.isEmpty { a.largeText = album }
        return a
    }
}

public enum DiscordFrame {
    /// op (UInt32 LE), length (UInt32 LE), then the JSON.
    public static func encode(op: DiscordOp, payload: Data) -> Data {
        var d = Data()
        for v in [op.rawValue, UInt32(payload.count)] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(payload)
        return d
    }

    public static func encode(op: DiscordOp, json: [String: Any]) -> Data {
        encode(op: op, payload: (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    public static func handshake(clientId: String) -> Data { encode(op: .handshake, json: ["v": 1, "client_id": clientId]) }

    /// A nil activity clears the presence.
    public static func setActivity(_ activity: DiscordActivity?, pid: Int32, nonce: String) -> Data {
        var args: [String: Any] = ["pid": Int(pid)]
        if let activity { args["activity"] = activity.json }
        return encode(op: .frame, json: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])
    }

    /// Takes whole frames off the front of `buffer`, leaving a partial one in place.
    public static func decode(_ buffer: inout Data) -> [(op: UInt32, payload: Data)] {
        var out: [(op: UInt32, payload: Data)] = []
        var buf = Data(buffer)
        while buf.count >= 8 {
            let op = buf.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
            let len = Int(buf.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
            // A length this large is not Discord; drop the buffer rather than wait for it.
            if len > 1 << 20 { buf = Data(); break }
            guard buf.count >= 8 + len else { break }
            out.append((op, buf.subdata(in: 8..<(8 + len))))
            buf = buf.subdata(in: (8 + len)..<buf.count)
        }
        buffer = buf
        return out
    }
}

/// Reconnect backoff: 15 s, doubling up to 60 s. "Discord is not running" is commonly a long
/// wait, not a blip, so it is not a fixed interval. Reset on a successful connection.
public struct RpcBackoff: Sendable {
    public static let minSeconds = 15.0, maxSeconds = 60.0
    private var delay = RpcBackoff.minSeconds
    public init() {}
    public mutating func next() -> Double { let d = delay; delay = min(delay * 2, Self.maxSeconds); return d }
    public mutating func reset() { delay = Self.minSeconds }
}

/// One presence update per 5 s at most: how long to hold an update that arrives now.
public func rpcSendWait(now: Double, lastSentAt: Double, minInterval: Double = 5) -> Double {
    max(0, minInterval - (now - lastSentAt))
}
