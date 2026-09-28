import SwiftUI
import CascadeKit

struct ArtistsView: View {
    @Environment(AppState.self) private var state
    /// Loaded and kept by AppState (see browseList), so it survives leaving
    /// this screen and keeps filling while it is off screen.
    @State private var list: BrowseList?
    private var items: [JfItem] { list?.items ?? [] }
    private var isLoading: Bool { list?.isLoading ?? true }
    private var error: String? { list?.error }
    @AppStorage("cascade.artists.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.artists.favorites") private var favoritesOnly = false
    /// Bumped by pull to refresh, so the reload misses the cache.
    @State private var refreshes = 0

    private var browseKey: BrowseKey {
        BrowseKey(libraries: state.config?.libraryIds, sort: "SortName",
                  direction: sortDirection, favoritesOnly: favoritesOnly, generation: refreshes)
    }

    var body: some View {
        ScrollView {
            HStack {
                // Name is the only order the album artists route is worth
                // sorting by, so this is direction and the filter.
                SortMenu(fields: [("name", "Name")], field: .constant("name"),
                         direction: $sortDirection, favoritesOnly: $favoritesOnly)
                Spacer()
            }
            .padding(.horizontal)
            .browseHeader()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Artists")
        // Keyed on the library selection and the sort, so changing either reloads.
        .refreshable { state.dropBrowseCache(.artists); refreshes += 1 }
        .task(id: browseKey) {
            guard let client = state.client else { return }
            let (order, favorites) = (sortDirection.serverValue, favoritesOnly)
            list = state.browseList(.artists, browseKey) { list in
                try await loadPaged(sortBy: "SortName", sortOrder: order, fetch: {
                    try await client.artists(limit: $0, startIndex: $1, sortOrder: order, favoritesOnly: favorites)
                }) {
                    list.items = $0
                    list.isLoading = false
                }
            }
        }
    }
}
