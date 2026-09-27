import Foundation

// Editing a queue that is already playing: Play Next, Add to Queue, reorder,
// remove. Pure, like Queue.swift; PlaybackService applies the result and then
// re-syncs the gapless preload, because any of these can change what plays
// next.
//
// Two rules hold for every function here. The track playing now stays the
// track playing now, so `index` follows it wherever it moves. And while
// shuffle is on, `unshuffled` gets the same additions and removals, so turning
// shuffle off still finds everything that was added while it was on.

/// Insert right after the current track ("Play Next"). With nothing playing
/// (index -1) that is the front.
public func playingNext(_ state: QueueOrder, _ items: [JfItem]) -> QueueOrder {
    var out = state
    out.items.insert(contentsOf: items, at: max(0, state.index + 1))
    if var saved = state.unshuffled {
        // After the current track in the saved order too, so it still plays
        // next-ish once shuffle is off rather than wherever it was appended.
        let at = state.current.flatMap { c in saved.firstIndex(of: c) }.map { $0 + 1 } ?? 0
        saved.insert(contentsOf: items, at: at)
        out.unshuffled = saved
    }
    return out
}

/// Append to the end ("Add to Queue").
public func appending(_ state: QueueOrder, _ items: [JfItem]) -> QueueOrder {
    var out = state
    out.items += items
    out.unshuffled? += items
    return out
}

/// Move rows the way SwiftUI's onMove reports it: `destination` is an offset
/// in the list BEFORE the move. Only the play order changes; the saved
/// pre-shuffle order is left alone, since that is the order being restored.
public func moving(_ state: QueueOrder, from offsets: IndexSet, to destination: Int) -> QueueOrder {
    let valid = offsets.filteredIndexSet { state.items.indices.contains($0) }
    guard !valid.isEmpty else { return state }
    let moved = valid.map { state.items[$0] }
    var rest = state.items
    for i in valid.reversed() { rest.remove(at: i) }
    let at = min(rest.count, max(0, destination - valid.count(in: 0..<max(0, destination))))
    rest.insert(contentsOf: moved, at: at)

    var out = state
    out.items = rest
    // Follow the current track by position, not by id: the same song can be
    // in the queue twice.
    if state.items.indices.contains(state.index) {
        if let k = valid.firstIndex(of: state.index) {
            out.index = at + valid.distance(from: valid.startIndex, to: k)
        } else {
            let kept = state.index - valid.count(in: 0..<state.index)
            out.index = kept >= at ? kept + moved.count : kept
        }
    }
    return out
}

/// Remove rows. The current track is never removed (the view does not offer
/// it), so this cannot leave the player pointing at nothing.
public func removing(_ state: QueueOrder, at offsets: IndexSet) -> QueueOrder {
    let doomed = offsets.filteredIndexSet { state.items.indices.contains($0) && $0 != state.index }
    guard !doomed.isEmpty else { return state }
    var out = state
    let removed = doomed.map { state.items[$0] }
    for i in doomed.reversed() { out.items.remove(at: i) }
    if state.index >= 0 { out.index = state.index - doomed.count(in: 0..<state.index) }
    if var saved = state.unshuffled {
        // One saved copy per removed row, so a song queued twice and removed
        // once is still there once.
        for item in removed {
            if let i = saved.firstIndex(of: item) { saved.remove(at: i) }
        }
        out.unshuffled = saved
    }
    return out
}

public extension JellyfinClient {
    /// Songs like this one, seeded from a track, album or artist. Checked
    /// against 10.11.11's spec: GET /Items/{itemId}/InstantMix.
    func instantMix(seedId: String, limit: Int = 50) async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/Items/\(seedId)/InstantMix", params: [
            "userId": currentConfig.userId,
            "limit": String(limit),
        ])
        return response.items ?? []
    }

    /// One item by id, with this user's data. Go to Album and Go to Artist
    /// use it, because a track only carries the album's and artist's id and
    /// name, and their pages want the rest.
    func item(id: String) async throws -> JfItem {
        try await get("/Items/\(id)", params: ["userId": currentConfig.userId])
    }
}
