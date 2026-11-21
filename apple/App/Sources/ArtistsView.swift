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
    @AppStorage("cascade.artistsPrefs") private var prefs = LibraryPrefs()
    /// Bumped by pull to refresh, so the reload misses the cache.
    @State private var refreshes = 0

    private var sortField: ArtistSortField { prefs.sortField(default: .name) }

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
            }
            .padding(.horizontal)
            .browseHeader()
            #endif
            #if os(macOS)
            VStack(alignment: .leading, spacing: 0) {
                CxPageHeader(title: "Artists", voice: voice) {
                    sortMenu(chip: true)
                } below: {
                    FilterChips(filter: $prefs.filter, itemType: "MusicArtist", favoritesOnly: true)
                }
                overlay
                ItemTiles(items: items)
            }
            .cxPage()
            #else
            overlay
            ItemTiles(items: items)
            #endif
        }
        .navigationTitle("Artists")
        // Keyed on the library selection and the sort, so changing either reloads.
        .refreshable { state.dropBrowseCache(.artists); refreshes += 1 }
        .task(id: browseKey) {
            guard let client = state.client else { return }
            let (field, order, filter) = (sortField, prefs.direction.serverValue, prefs.filter)
            list = state.browseList(.artists, browseKey, localSort: field.serverSortBy) { list in
                try await loadPaged(sortBy: field.serverSortBy, sortOrder: order, fetch: {
                    try await client.artists(limit: $0, startIndex: $1, sortBy: field.serverSortBy,
                                             sortOrder: order, filter: filter)
                }) {
                    list.items = $0
                    list.isLoading = false
                }
            }
        }
    }

    private var overlay: some View {
        LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid,
                       emptyTitle: "No artists", emptyMessage: "Nothing matches, or the chosen libraries are empty.",
                       retry: { state.dropBrowseCache(.artists); refreshes += 1 })
    }

    private func sortMenu(chip: Bool = false) -> some View {
        SortMenu(fields: [(ArtistSortField.name, "Name"), (.added, "Date Added")],
                 field: $prefs.sort(.name) { $0.defaultDirection }, direction: $prefs.direction, chip: chip)
    }

    #if os(macOS)
    private var voice: String? {
        guard let list, list.isComplete, list.isWholeList, !items.isEmpty else { return nil }
        return cxCount(items.count, "artist")
    }
    #endif

    @ViewBuilder private var controls: some View {
        sortMenu()
        // Favorites only: the desktop offers an artist no genre (Jellyfin
        // filters artists by their own genre metadata, which is mostly empty),
        // no year, and "played" means nothing for one.
        FilterMenu(filter: $prefs.filter, itemType: "MusicArtist",
                   showsGenre: false, showsDecade: false, showsPlayed: false)
    }
}
