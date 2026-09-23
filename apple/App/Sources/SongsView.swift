import SwiftUI
import CascadeKit

struct SongsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var sortField: SongSortField = .name
    @State private var sortDirection: SortDirection = .ascending

    private var sorted: [JfItem] {
        sortSongs(items, by: sortField, sortDirection)
    }

    var body: some View {
        List {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, song in
                Button {
                    Task { await state.player?.play(sorted, startIndex: index) }
                } label: {
                    TrackRow(track: song)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                sortControl
            }
        }
        // Keyed on the library selection, so changing it in Settings reloads.
        .task(id: state.config?.libraryIds) {
            guard let client = state.client else { return }
            isLoading = true
            error = nil
            do {
                try await loadPaged(fetch: { try await client.songs(limit: $0, startIndex: $1) }) {
                    items = $0
                    isLoading = false
                }
            } catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    // Menu reads fine on iOS; tvOS focus handles Menu poorly for compact
    // controls, so it gets a Picker instead.
    @ViewBuilder
    private var sortControl: some View {
        #if os(tvOS)
        HStack {
            Picker("Sort", selection: $sortField) {
                ForEach(SongSortField.allCases, id: \.self) { field in
                    Text(label(for: field)).tag(field)
                }
            }
            Picker("Direction", selection: $sortDirection) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
        }
        #else
        Menu {
            Picker("Sort by", selection: $sortField) {
                ForEach(SongSortField.allCases, id: \.self) { field in
                    Text(label(for: field)).tag(field)
                }
            }
            Picker("Direction", selection: $sortDirection) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        #endif
    }

    private func label(for field: SongSortField) -> String {
        switch field {
        case .name: return "Name"
        case .artist: return "Artist"
        case .album: return "Album"
        case .added: return "Date Added"
        case .played: return "Last Played"
        }
    }
}
