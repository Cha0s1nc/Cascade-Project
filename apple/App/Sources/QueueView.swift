import SwiftUI
import CascadeKit

#if !os(tvOS)
/// The queue on iOS as its own sheet: tap a row to play it, Edit to drag or
/// delete. tvOS shows its queue beside the player instead, and has no drag to
/// reorder with.
struct QueueView: View {
    let player: PlaybackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                QueueList(player: player)
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The queue's rows: tap to play, drag to reorder, delete, and the "Add Next"
/// row while the queue came from a list still being paged in. Shared by the
/// queue sheet (the whole queue) and Now Playing's queue mode (only what plays
/// next), so the index arithmetic lives in one place.
struct QueueList: View {
    let player: PlaybackService
    /// Only the tracks after the current one, Apple Music's "Up Next".
    var upcomingOnly = false
    /// Now Playing keeps the list in edit mode for its drag handles, where a
    /// delete button on every row would be clutter; rows are removed from
    /// their long-press menu instead.
    var deleteFromMenu = false

    /// Rows are queue positions, not items: the same song can be queued
    /// twice, so ids repeat. The first row shown is `start`, which every
    /// offset SwiftUI reports is shifted by.
    private var start: Int { upcomingOnly ? max(0, player.queue.index + 1) : 0 }

    var body: some View {
        ForEach(start..<max(start, player.queue.items.count), id: \.self) { index in
            let isCurrent = index == player.queue.index
            Button {
                Task { await player.jump(to: index) }
            } label: {
                TrackRow(track: player.queue.items[index], showsMenu: false)
                    .fontWeight(isCurrent ? .semibold : .regular)
            }
            .buttonStyle(.plain)
            .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : (deleteFromMenu ? Color.clear : nil))
            // Removing what is playing would leave nothing to show as
            // playing; skip it or stop instead.
            .deleteDisabled(isCurrent || deleteFromMenu)
            .contextMenu {
                if deleteFromMenu && !isCurrent {
                    Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) {
                        player.removeQueueItems(at: IndexSet(integer: index))
                    }
                }
            }
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
        .onMove { offsets, destination in
            player.moveQueueItems(from: IndexSet(offsets.map { $0 + start }), to: destination + start)
        }
        .onDelete { offsets in
            player.removeQueueItems(at: IndexSet(offsets.map { $0 + start }))
        }
        // The queue also tops itself up near its end; this is for wanting
        // more in it now (see PlaybackService.loadMoreQueue).
        if player.hasMoreQueue {
            Button {
                Task { await player.loadMoreQueue() }
            } label: {
                Label(player.isLoadingMoreQueue ? "Adding…" : "Add Next \(PlaybackService.queuePageSize) Songs",
                      systemImage: "text.badge.plus")
            }
            .disabled(player.isLoadingMoreQueue)
            .listRowBackground(deleteFromMenu ? Color.clear : nil)
            .moveDisabled(true)
            .deleteDisabled(true)
        }
    }
}
#endif
