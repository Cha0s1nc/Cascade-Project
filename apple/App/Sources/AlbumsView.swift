import SwiftUI
import CascadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    // Remembered between launches. A stored value that no longer names a
    // case falls back to the default rather than reaching the server.
    @AppStorage("cascade.albums.sort") private var sortField: AlbumSortField = .name
    @AppStorage("cascade.albums.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.albums.favorites") private var favoritesOnly = false

    var body: some View {
        ScrollView {
            HStack {
                SortMenu(fields: [(AlbumSortField.name, "Name"), (.artist, "Artist"), (.year, "Year"),
                                  (.added, "Date Added"), (.played, "Recently Played")],
                         field: $sortField, direction: $sortDirection, favoritesOnly: $favoritesOnly)
                Spacer()
            }
            .padding(.horizontal)
            .browseHeader()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Albums")
        .onChange(of: sortField) { sortDirection = sortField.defaultDirection }
        // Keyed on the library selection and the sort, so changing either
        // reloads from the server rather than re-sorting a partial list.
        .task(id: BrowseKey(libraries: state.config?.libraryIds, sort: sortField.rawValue,
                            direction: sortDirection, favoritesOnly: favoritesOnly)) {
            guard let client = state.client else { return }
            isLoading = true
            error = nil
            // Cleared first: an empty result (no favorites) never calls apply,
            // and would otherwise leave the previous list up.
            items = []
            let (field, order, favorites) = (sortField, sortDirection.serverValue, favoritesOnly)
            do {
                if let sortBy = field.serverSortBy {
                    try await loadPaged(sortBy: sortBy, sortOrder: order, fetch: {
                        try await client.albums(limit: $0, startIndex: $1, sortBy: sortBy,
                                                sortOrder: order, favoritesOnly: favorites)
                    }) {
                        items = $0
                        isLoading = false
                    }
                } else {
                    // Recently played comes back newest first, which is
                    // Descending, like Date Added.
                    let recent = try await client.recentlyPlayedAlbums(favoritesOnly: favorites)
                    items = sortDirection == .descending ? recent : recent.reversed()
                }
            } catch {
                // A superseded load's cancellation is not an error to show.
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
    }
}
