import Foundation

// Waterfall's wire format and sync maths: the desktop's
// src/core/waterfall-protocol.ts, ported with its tests, so this app joins
// the same rooms as the desktop through the same relay.
//
// A room keeps members in sync without any audio crossing the wire: everyone
// streams the same track from the same Jellyfin server, and the room only
// carries "track X, position Y, playing/paused". The host owns playback;
// guests follow, and ask the host for anything else.

/// One message's payload, flat as the desktop sends it: `k` says which kind,
/// and each kind uses its own few fields. Read from another client, so every
/// field is optional and checked where it is used.
public struct WfMessage: Codable, Sendable, Equatable {
    public var k: String
    public var serverId: String?
    // state
    public var trackId: String?
    public var positionMs: Double?
    public var paused: Bool?
    /// The sender's wall clock (ms since 1970), to age a position in transit.
    public var sentAt: Double?
    /// The host's queue index (state and queue).
    public var index: Int?
    // queue
    public var rev: Int?
    public var trackIds: [String]?
    /// Parallel to trackIds: the guest who added each, nil for the host's own.
    public var addedBy: [String?]?
    public var guestAddsAllowed: Bool?
    public var guestControlAllowed: Bool?
    // control
    public var action: String?
    // enqueue-rejected
    public var reason: String?

    public init(k: String, serverId: String? = nil) {
        self.k = k
        self.serverId = serverId
    }
}

public enum Waterfall {
    /// The relay the desktop defaults to (signaling/ in the desktop repo).
    public static let defaultRelay = "https://cascade-waterfall-signaling.cha0s-netw0rks.workers.dev"

    /// The host re-announces its position this often.
    public static let heartbeatMs = 4000.0
    /// A guest re-seeks once it is at least this far out.
    public static let driftMs = 1500.0
    /// The most a guest leads a seek by, however slow the last one was.
    public static let maxSeekLeadMs = 5000.0
    /// How many recent state messages the clock offset looks at.
    public static let skewWindow = 30

    public enum ControlAction: String, CaseIterable, Sendable {
        case playpause, next, prev, seek
    }

    public static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    public static func state(serverId: String?, trackId: String, positionMs: Double, paused: Bool,
                             index: Int? = nil, now: Double = nowMs()) -> WfMessage {
        var m = WfMessage(k: "state", serverId: serverId)
        m.trackId = trackId
        m.positionMs = positionMs
        m.paused = paused
        m.index = index
        m.sentAt = now
        return m
    }

    public static func queue(serverId: String?, rev: Int, trackIds: [String], addedBy: [String?] = [],
                             index: Int, guestAddsAllowed: Bool, guestControlAllowed: Bool) -> WfMessage {
        var m = WfMessage(k: "queue", serverId: serverId)
        m.rev = rev
        m.trackIds = trackIds
        // Same length as the tracks, so a drifted list cannot ship misaligned.
        m.addedBy = aligned(addedBy, to: trackIds.count)
        m.index = index
        m.guestAddsAllowed = guestAddsAllowed
        m.guestControlAllowed = guestControlAllowed
        return m
    }

    public static func aligned(_ addedBy: [String?], to count: Int) -> [String?] {
        Array(addedBy.prefix(count)) + Array(repeating: nil, count: max(0, count - addedBy.count))
    }

    public static func control(_ action: ControlAction, positionMs: Double? = nil) -> WfMessage {
        var m = WfMessage(k: "control")
        m.action = action.rawValue
        if action == .seek, let positionMs, positionMs.isFinite { m.positionMs = max(0, positionMs.rounded()) }
        return m
    }

    /// Arrives from another client: only a known action is acted on.
    public static func controlAction(_ raw: String?) -> ControlAction? { raw.flatMap(ControlAction.init) }

    public static func enqueue(serverId: String?, trackIds: [String]) -> WfMessage {
        var m = WfMessage(k: "enqueue", serverId: serverId)
        m.trackIds = trackIds
        return m
    }

    public static func enqueueRejected(_ reason: String) -> WfMessage {
        var m = WfMessage(k: "enqueue-rejected")
        m.reason = reason
        return m
    }

    /// A queue message older than the one applied: state and queue travel
    /// separately, and a late one would clobber a newer queue.
    public static func isStaleQueue(_ incoming: Int, lastApplied: Int) -> Bool { incoming <= lastApplied }

    /// The host's track ids this member has nothing for yet, once each.
    public static func missingTrackIds(_ ids: [String], known: Set<String>) -> [String] {
        var seen = Set<String>()
        return ids.filter { !known.contains($0) && seen.insert($0).inserted }
    }

    /// Where the host is now: its position aged by the time in transit, the
    /// clock difference (`offsetMs`, from clockOffsetMs) taken back out.
    public static func expectedPositionMs(_ state: WfMessage, now: Double = nowMs(), offsetMs: Double = 0) -> Double {
        let latency = max(0, now - (state.sentAt ?? now) - offsetMs)
        return (state.positionMs ?? 0) + (state.paused == true ? 0 : latency)
    }

    /// Where to seek so the guest comes out level with the host: a seek into
    /// a remote stream takes a while, and the host plays on meanwhile, so it
    /// leads by the last seek's time. A paused host is not moving.
    public static func seekTargetMs(expectedMs: Double, lastSeekMs: Double, paused: Bool) -> Double {
        if paused { return max(0, expectedMs) }
        return max(0, expectedMs + min(max(0, lastSeekMs), maxSeekLeadMs))
    }

    /// This member's clock minus the host's: the smallest arrival-minus-sent
    /// over recent states, which is the difference plus the fastest trip.
    public static func clockOffsetMs(_ samples: [Double]) -> Double { samples.min() ?? 0 }

    /// Past the threshold only: nudging every tick would be audible.
    public static func shouldReseek(currentMs: Double, expectedMs: Double, driftMs: Double = driftMs) -> Bool {
        abs(currentMs - expectedMs) > driftMs
    }

    /// A member on another Jellyfin server cannot stream the host's tracks.
    /// An unknown id passes, so an older client is not locked out.
    public static func isForeignServer(_ peer: String?, _ own: String?) -> Bool {
        guard let peer, !peer.isEmpty, let own, !own.isEmpty else { return false }
        return peer != own
    }

    /// The relay's base (http) to the room's socket (ws), name attached.
    public static func roomSocketUrl(relayBase: String, code: String, name: String) -> URL? {
        var base = relayBase
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("http") { base = "ws" + base.dropFirst(4) }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        return URL(string: "\(base)/room/\(code)?name=\(encoded)")
    }

    /// Room codes: six of the relay's characters (no 0/O/1/I/L).
    public static func normalizedCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.count == 6 && code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? code : nil
    }
}
