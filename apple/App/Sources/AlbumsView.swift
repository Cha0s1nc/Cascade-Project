import SwiftUI
import CascadeKit

struct AlbumsView: View {
    @Environment(AppState.self) private var state
    /// Loaded and kept by AppState (see browseList), so it survives leaving
    /// this screen and keeps filling while it is off screen.
    @State private var list: BrowseList?
    private var items: [JfItem] { list?.items ?? [] }
    private var isLoading: Bool { list?.isLoading ?? true }
    private var error: String? { list?.error }
    // Remembered between launches. A stored value that no longer names a
    // case falls back to the default rather than reaching the server.
    @AppStorage("cascade.albums.sort") private var sortField: AlbumSortField = .name
    @AppStorage("cascade.albums.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.albums.favorites") private var favoritesOnly = false
    /// Bumped by pull to refresh, so the reload misses the cache.
    @State private var refreshes = 0

    private var browseKey: BrowseKey {
        BrowseKey(libraries: state.config?.libraryIds, sort: sortField.rawValue,
                  direction: sortDirection, favoritesOnly: favoritesOnly, generation: refreshes)
    }

    var body: some View {
        ScrollView {
            HStack {
                SortMenu(fields: [(AlbumSortField.name, "Name"), (.artist, "Artist"), (.year, "Year"),
                                  (.added, "Date Added"), (.played, "Recently Played")],
                         field: $sortField, direction: $sortDirection, favoritesOnly: $favoritesOnly)
                Spacer()
                NavigationLink(value: AppRoute.genres) {
                    Label("Genres", systemImage: "guitars")
                }
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
        .refreshable { state.dropBrowseCache(.albums); refreshes += 1 }
        .task(id: browseKey) {
            guard let client = state.client else { return }
            let (field, direction, favorites) = (sortField, sortDirection, favoritesOnly)
            list = state.browseList(.albums, browseKey) { list in
                if let sortBy = field.serverSortBy {
                    try await loadPaged(sortBy: sortBy, sortOrder: direction.serverValue, fetch: {
                        try await client.albums(limit: $0, startIndex: $1, sortBy: sortBy,
                                                sortOrder: direction.serverValue, favoritesOnly: favorites)
                    }) {
                        list.items = $0
                        list.isLoading = false
                    }
                } else {
                    // Recently played comes back newest first, which is
                    // Descending, like Date Added.
                    let recent = try await client.recentlyPlayedAlbums(favoritesOnly: favorites)
                    list.items = direction == .descending ? recent : recent.reversed()
                }
            }
        }
    }
}
