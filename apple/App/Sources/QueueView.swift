import SwiftUI
import CascadeKit

#if !os(tvOS)
/// The queue on iOS, opened from Now Playing: tap a row to play it, Edit to
/// drag or delete. tvOS shows its queue beside the player instead, and has no
/// drag to reorder with.
struct QueueView: View {
    let player: PlaybackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // By offset: the same song can be queued twice, so ids repeat.
                ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, track in
                    let isCurrent = index == player.queue.index
                    Button {
                        Task { await player.jump(to: index) }
                    } label: {
                        TrackRow(track: track, showsMenu: false)
                            .fontWeight(isCurrent ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(isCurrent ? Color.accentColor.opacity(0.15) : nil)
                    // Removing what is playing would leave nothing to show as
                    // playing; skip it or stop instead.
                    .deleteDisabled(isCurrent)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
                .onMove { player.moveQueueItems(from: $0, to: $1) }
                .onDelete { player.removeQueueItems(at: $0) }
                // The queue also tops itself up near its end; this is for
                // wanting more in it now (see PlaybackService.loadMoreQueue).
                if player.hasMoreQueue {
                    Button {
                        Task { await player.loadMoreQueue() }
                    } label: {
                        Label(player.isLoadingMoreQueue ? "Adding…" : "Add Next \(PlaybackService.queuePageSize) Songs",
                              systemImage: "text.badge.plus")
                    }
                    .disabled(player.isLoadingMoreQueue)
                }
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
#endif
