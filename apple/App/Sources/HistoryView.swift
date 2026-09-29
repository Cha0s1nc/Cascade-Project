import SwiftUI
import CascadeKit

/// Everything this user has played, newest first and grouped by day: the
/// desktop's History view. Tapping a song plays on through the rest of the
/// history from there, not just that day.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        let days = PlayHistory.byDay(items)
        List {
            ForEach(days) { day in
                Section(day.label) {
                    ForEach(day.items) { track in
                        Button {
                            // The flat list's index, so play continues past this day.
                            let index = items.firstIndex { $0.id == track.id } ?? 0
                            Task { await state.player?.play(items, startIndex: index) }
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(track)
                    }
                }
            }
            if items.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true)
            }
        }
        .navigationTitle("History")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            items = try await client.playHistory()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
