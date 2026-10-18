import Foundation

// Sending what happened offline (docs/offline-mode-plan.md, section 5). Pure:
// OfflineLibrary fetches and posts, this decides. The desktop's
// src/core/offline-sync.ts is the same rules, and both pass
// test/fixtures/offline-sync.json.
//
// Two kinds of thing are sent, by two rules:
// - Plays are history. They are replayed only when the server's history still
//   matches the snapshot taken while online (nothing was played anywhere else
//   meanwhile), oldest first with their own dates; otherwise they are held for
//   the person to add or discard.
// - Positions, played marks and favorites are per item. Coalesced first, each
//   is sent only when the server's LastPlayedDate is older than the change.
public enum OfflineSync {
    /// The history the snapshot keeps, and the list reconnecting compares
    /// with: one request, the same on both apps, across every library.
    public static let historyQuery: [String: String?] = [
        "filters": "IsPlayed", "sortBy": "DatePlayed", "sortOrder": "Descending", "recursive": "true",
        "includeItemTypes": "Audio,Movie,Episode", "limit": String(OfflineIndex.maxHistoryEntries),
    ]

    /// The fields for POST /UserItems/{id}/UserData, PascalCase on the wire.
    public struct UserDataBody: Codable, Sendable, Equatable {
        public var playbackPositionTicks: Int?
        public var played: Bool?
        public var lastPlayedDate: String?
    }

    /// What to send for one item: user data, a favorite, or both.
    public struct Send: Codable, Sendable, Equatable {
        public var userData: UserDataBody?
        public var favorite: Bool?
    }

    /// What one item's queued changes come to.
    public struct PendingUpdate: Codable, Sendable, Equatable {
        public var itemId: String
        public var userId: String
        /// The latest change's time: what the conflict rule compares.
        public var at: String
        public var userData: UserDataBody?
        public var favorite: Bool?
    }

    /// Each item's changes as one update, in the order items were first
    /// changed. Later changes win (only the last position matters); a
    /// favorite that ends where it started is no change.
    public static func coalesce(_ changes: [OfflineIndex.UserDataChange]) -> [PendingUpdate] {
        let ordered = changes.enumerated().sorted {
            let (a, b) = (OfflineQuery.time($0.element.at) ?? 0, OfflineQuery.time($1.element.at) ?? 0)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        var order: [String] = []
        var updates: [String: PendingUpdate] = [:]
        var firstWas: [String: Bool] = [:]
        for c in ordered {
            let key = "\(c.userId)/\(c.itemId)"
            if updates[key] == nil {
                order.append(key)
                updates[key] = PendingUpdate(itemId: c.itemId, userId: c.userId, at: c.at)
            }
            updates[key]!.at = c.at
            if c.kind == .favorite {
                if firstWas[key] == nil { firstWas[key] = c.was ?? !(c.favorite ?? false) }
                updates[key]!.favorite = c.favorite ?? false
                continue
            }
            var ud = updates[key]!.userData ?? UserDataBody()
            switch c.kind {
            case .position:
                ud.playbackPositionTicks = c.ticks ?? 0
                ud.lastPlayedDate = c.at
            case .played where c.played == true:
                ud.played = true
                ud.playbackPositionTicks = 0
                ud.lastPlayedDate = c.at
            default:
                ud.played = false
                ud.playbackPositionTicks = 0
            }
            updates[key]!.userData = ud
        }
        return order.compactMap { key in
            guard var u = updates[key] else { return nil }
            if let f = u.favorite, f == firstWas[key] { u.favorite = nil }
            return u.userData != nil || u.favorite != nil ? u : nil
        }
    }

    /// What to send for one update, given the item as the server has it now
    /// (nil: the server no longer has it, so nothing). The change wins only
    /// when the server's LastPlayedDate is older than it: a position set on
    /// the TV after this device went offline is newer, and stays. Fields the
    /// server already holds are left out; nil when nothing is left.
    public static func toSend(_ update: PendingUpdate, server: JfItem?) -> Send? {
        guard let server else { return nil }
        let sud = server.userData
        if let serverAt = OfflineQuery.time(sud?.lastPlayedDate), serverAt >= (OfflineQuery.time(update.at) ?? 0) { return nil }
        var out = Send()
        if var ud = update.userData {
            if let p = ud.played, p == (sud?.played ?? false) { ud.played = nil }
            if let t = ud.playbackPositionTicks, t == (sud?.playbackPositionTicks ?? 0), ud.played == nil { ud.playbackPositionTicks = nil }
            // A date alone changes nothing a person sees.
            if ud.played != nil || ud.playbackPositionTicks != nil { out.userData = ud }
        }
        if let f = update.favorite, f != (sud?.isFavorite ?? false) { out.favorite = f }
        return out.userData != nil || out.favorite != nil ? out : nil
    }

    /// One fixed order for a list of rows, newest first and ties by id: the
    /// server may order two plays with one date either way from one request
    /// to the next. Byte order, the desktop's text order; both lists go
    /// through it, so it only has to be the same order every time.
    static func ordered(_ entries: [OfflineIndex.HistoryEntry]) -> [OfflineIndex.HistoryEntry] {
        entries.sorted { a, b in
            let (da, db) = (a.lastPlayedDate ?? "", b.lastPlayedDate ?? "")
            if !da.utf8.elementsEqual(db.utf8) { return db.utf8.lexicographicallyPrecedes(da.utf8) }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
    }

    /// Whether the server's history (historyQuery's answer) is the
    /// snapshot's: same items, dates and counts. No snapshot never matches.
    public static func snapshotMatches(_ snapshot: OfflineIndex.History?, server: [JfItem]) -> Bool {
        guard let snapshot else { return false }
        return ordered(snapshot.entries) == ordered(OfflineIndex.historyEntries(of: server))
    }

    public enum CatchUp: String, Sendable { case none, replay, hold }

    /// What to do with the plays queued offline, back online: nothing,
    /// replay them, or hold them for the person (already held, or someone
    /// played on this account elsewhere meanwhile).
    public static func catchUp(plays: [OfflineIndex.Play], history: OfflineIndex.History?, held: Bool,
                               server: [JfItem]) -> CatchUp {
        if plays.isEmpty { return .none }
        if held { return .hold }
        return snapshotMatches(history, server: server) ? .replay : .hold
    }

    /// The order plays are replayed in, so the server's history reads as if
    /// they had happened online.
    public static func oldestFirst(_ plays: [OfflineIndex.Play]) -> [OfflineIndex.Play] {
        plays.enumerated().sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }
            .map(\.element)
    }
}
