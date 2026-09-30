import Foundation

// Queue ordering: sorting, shuffling, and what plays next. Pure, no player.
//
// These rules once lived in the desktop's renderer.js on the grounds that they
// were "mostly button painting". Only the buttons were. The decisions
// underneath, where shuffle puts the currently playing track and what a queue
// does when it runs out, are real behaviour every platform has to reproduce
// exactly, so they live here and each host keeps its own buttons.

public enum SongSortField: String, Sendable, CaseIterable {
    case name, artist, album, added, played
}

public enum SortDirection: String, Sendable {
    case ascending, descending
}

/// Sort key for a track. Strings are lowercased; dates become time intervals.
func sortValue(_ item: JfItem, _ field: SongSortField) -> String {
    switch field {
    case .artist: return (item.albumArtist ?? item.artists?.first ?? "").lowercased()
    case .album:  return (item.album ?? "").lowercased()
    // Dates are ISO 8601, which sorts correctly as text, so this avoids parsing
    // a timestamp just to compare two of them.
    case .added:  return item.dateCreated ?? ""
    case .played: return item.userData?.lastPlayedDate ?? ""
    case .name:   return (item.name ?? "").lowercased()
    }
}

public func sortSongs(_ items: [JfItem], by field: SongSortField,
                      _ direction: SortDirection = .ascending) -> [JfItem] {
    items.sorted { a, b in
        let (va, vb) = (sortValue(a, field), sortValue(b, field))
        // Ties broken by name so the order is stable between two runs, which
        // matters when a whole album shares a sort key.
        if va == vb { return (a.name ?? "") < (b.name ?? "") }
        return direction == .descending ? va > vb : va < vb
    }
}

/// none: play through and stop. all: wrap. one: replay this track.
public enum RepeatMode: String, Sendable, CaseIterable {
    case none, all, one

    /// Next mode for a press of the repeat button, matching the desktop's cycle.
    public var next: RepeatMode {
        switch self {
        case .none: return .all
        case .all:  return .one
        case .one:  return .none
        }
    }
}

/// A queue and where we are in it.
public struct QueueOrder: Sendable, Equatable {
    public var items: [JfItem]
    public var index: Int
    /// The pre-shuffle order, kept only while shuffle is on.
    public var unshuffled: [JfItem]?

    public init(items: [JfItem] = [], index: Int = -1, unshuffled: [JfItem]? = nil) {
        self.items = items
        self.index = index
        self.unshuffled = unshuffled
    }

    public var current: JfItem? {
        items.indices.contains(index) ? items[index] : nil
    }
}

/// Turn shuffle on or off, keeping the current track playing.
///
/// Two details that look like fussiness and are not, both carried over from the
/// desktop:
///
/// Turning shuffle ON moves the current track to the front and sets the index
/// to 0 rather than shuffling around it. Without that, the track playing right
/// now would jump to a random position, and everything before it would be
/// skipped the moment it ended.
///
/// Turning shuffle OFF restores the saved order and finds the current track in
/// it BY ID rather than reusing the index. An index means nothing across a
/// reorder, and reusing it lands on an unrelated track.
public func setShuffle(_ state: QueueOrder, on: Bool) -> QueueOrder {
    let currentId = state.current?.id

    if on {
        // Already on: leave it, or we reshuffle and lose the saved order.
        guard state.unshuffled == nil else { return state }

        // ponytail: the system RNG is fine here. This shuffles a play queue,
        // not anything that has to resist prediction.
        var items = state.items.shuffled()
        if let currentId, let at = items.firstIndex(where: { $0.id == currentId }), at > 0 {
            items.insert(items.remove(at: at), at: 0)
        }
        return QueueOrder(items: items, index: items.isEmpty ? -1 : 0, unshuffled: state.items)
    }

    guard let items = state.unshuffled else { return state }
    let at = currentId.flatMap { id in items.firstIndex(where: { $0.id == id }) }
    return QueueOrder(items: items, index: at ?? 0, unshuffled: nil)
}

/// What should happen when the current track finishes on its own.
public enum QueueAdvance: Sendable, Equatable {
    case restart
    case play(index: Int)
    case stop
}

/// What plays when a track ends by itself.
///
/// Separate from `manualNextIndex` because the two genuinely differ: repeat-one
/// replays the track when it ends, but pressing next with repeat-one on should
/// move to the next track. A player that refused to skip would read as broken.
public func advanceOnEnd(length: Int, index: Int, repeatMode: RepeatMode) -> QueueAdvance {
    guard length > 0 else { return .stop }
    if repeatMode == .one { return .restart }

    let next = index + 1
    if next < length { return .play(index: next) }
    return repeatMode == .all ? .play(index: 0) : .stop
}

/// Index for the next button, or nil if there is nothing to move to.
public func manualNextIndex(length: Int, index: Int, repeatMode: RepeatMode) -> Int? {
    guard length > 0 else { return nil }
    let next = index + 1
    if next < length { return next }
    return repeatMode == .all ? 0 : nil
}

/// Index for the previous button, or nil if there is nothing to move to.
public func manualPreviousIndex(length: Int, index: Int, repeatMode: RepeatMode) -> Int? {
    guard length > 0 else { return nil }
    let previous = index - 1
    if previous >= 0 { return previous }
    return repeatMode == .all ? length - 1 : nil
}
