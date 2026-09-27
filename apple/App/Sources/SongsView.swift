import SwiftUI
import CascadeKit

struct SongsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @AppStorage("cascade.songs.sort") private var sortField: SongSortField = .name
    @AppStorage("cascade.songs.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.songs.favorites") private var favoritesOnly = false

    var body: some View {
        List {
            HStack {
                SortMenu(fields: [(SongSortField.name, "Title"), (.artist, "Artist"), (.album, "Album"),
                                  (.added, "Date Added"), (.played, "Date Last Played")],
                         field: $sortField, direction: $sortDirection, favoritesOnly: $favoritesOnly)
                Spacer()
            }
            // Borderless, or the List makes the whole row one button and a
            // tap anywhere on it fires every control in it.
            .buttonStyle(.borderless)
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, song in
                Button {
                    Task { await state.player?.play(items, startIndex: index) }
                } label: {
                    TrackRow(track: song)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Songs")
        .onChange(of: sortField) { sortDirection = sortField.defaultDirection }
        // The server sorts, not this view. Sorting here (sortSongs) only
        // sorted the pages loaded so far, so the first rows were wrong until
        // the last page landed. sortSongs' plain lowercase compare also
        // disagrees with Jellyfin's SortName collation, so re-sorting the
        // server's pages with it made rows jump as pages arrived.
        .task(id: BrowseKey(libraries: state.config?.libraryIds, sort: sortField.rawValue,
                            direction: sortDirection, favoritesOnly: favoritesOnly)) {
            guard let client = state.client else { return }
            isLoading = true
            error = nil
            items = []
            let (sortBy, order, favorites) = (sortField.serverSortBy, sortDirection.serverValue, favoritesOnly)
            do {
                try await loadPaged(sortBy: sortBy, sortOrder: order, fetch: {
                    try await client.songs(limit: $0, startIndex: $1, sortBy: sortBy,
                                           sortOrder: order, favoritesOnly: favorites)
                }) {
                    items = $0
                    isLoading = false
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
    }
}
