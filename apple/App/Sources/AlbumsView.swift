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
    // Remembered between launches in the desktop's shape (cascade.albumsPrefs).
    // A stored value that does not read back, or names a field this screen
    // does not offer, falls back to the default rather than reaching the server.
    @AppStorage("cascade.albumsPrefs") private var prefs = LibraryPrefs()
    /// Bumped by pull to refresh, so the reload misses the cache.
    @State private var refreshes = 0

    private var sortField: AlbumSortField { prefs.sortField(default: .name) }

    private var browseKey: BrowseKey {
        BrowseKey(libraries: state.config?.libraryIds, sort: sortField.rawValue,
                  direction: prefs.direction, filter: prefs.filter, generation: refreshes)
    }

    var body: some View {
        ScrollView {
            #if !os(macOS)
            HStack {
                controls
                Spacer()
                NavigationLink(value: AppRoute.genres) {
                    Label("Genres", systemImage: "guitars")
                }
            }
            .padding(.horizontal)
            .browseHeader()
            #endif
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid)
            ItemGrid(items: items)
        }
        .navigationTitle("Albums")
        #if os(macOS)
        // In the window toolbar, where a Mac app keeps them.
        .toolbar {
            ToolbarItemGroup { controls }
        }
        #endif
        // Keyed on the library selection and the sort, so changing either
        // reloads from the server rather than re-sorting a partial list.
        .refreshable { state.dropBrowseCache(.albums); refreshes += 1 }
        .task(id: browseKey) {
            guard let client = state.client else { return }
            let (field, direction, filter) = (sortField, prefs.direction, prefs.filter)
            list = state.browseList(.albums, browseKey, localSort: field.serverSortBy) { list in
                if let sortBy = field.serverSortBy {
                    try await loadPaged(sortBy: sortBy, sortOrder: direction.serverValue, fetch: {
                        try await client.albums(limit: $0, startIndex: $1, sortBy: sortBy,
                                                sortOrder: direction.serverValue, filter: filter)
                    }) {
                        list.items = $0
                        list.isLoading = false
                    }
                } else {
                    // Recently played comes back newest first, which is
                    // Descending, like Date Added.
                    let recent = try await client.recentlyPlayedAlbums(filter: filter)
                    list.items = direction == .descending ? recent : recent.reversed()
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        SortMenu(fields: [(AlbumSortField.name, "Name"), (.artist, "Artist"), (.year, "Year"),
                          (.added, "Date Added"), (.played, "Recently Played")],
                 field: $prefs.sort(.name) { $0.defaultDirection }, direction: $prefs.direction)
        FilterMenu(filter: $prefs.filter, itemType: "MusicAlbum")
        #if os(macOS)
        NavigationLink(value: AppRoute.genres) {
            Label("Genres", systemImage: "guitars")
        }
        #endif
    }
}
