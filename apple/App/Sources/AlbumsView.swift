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
            #if os(macOS)
            VStack(alignment: .leading, spacing: 0) {
                CxPageHeader(title: "Albums", voice: voice) {
                    sortMenu(chip: true)
                    PillButton("Shuffle", symbol: "shuffle") { Task { await shuffleAlbums() } }
                        .disabled(items.isEmpty)
                } below: {
                    FilterChips(filter: $prefs.filter, itemType: "MusicAlbum")
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
        .navigationTitle("Albums")
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

    private var overlay: some View {
        LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid,
                       emptyTitle: "No albums", emptyMessage: "Nothing matches, or the chosen libraries are empty.",
                       retry: { state.dropBrowseCache(.albums); refreshes += 1 })
    }

    private func sortMenu(chip: Bool = false) -> some View {
        SortMenu(fields: [(AlbumSortField.name, "Name"), (.artist, "Artist"), (.year, "Year"),
                          (.added, "Date Added"), (.played, "Recently Played")],
                 field: $prefs.sort(.name) { $0.defaultDirection }, direction: $prefs.direction, chip: chip)
    }

    @ViewBuilder private var controls: some View {
        sortMenu()
        FilterMenu(filter: $prefs.filter, itemType: "MusicAlbum")
    }

    #if os(macOS)
    /// "1,204 albums, 310 you haven't played yet", once the whole list is in: a count of
    /// the pages so far would be wrong.
    private var voice: String? {
        guard let list, list.isComplete, list.isWholeList, !items.isEmpty else { return nil }
        let unplayed = items.count { $0.userData?.played != true }
        return cxCount(items.count, "album") + (unplayed > 0 && unplayed < items.count ? ", \(unplayed.formatted()) you haven\u{2019}t played yet" : "")
    }

    /// Flutter's Albums Shuffle: the songs of 20 albums picked at random from those shown.
    private func shuffleAlbums() async {
        var songs: [JfItem] = []
        for album in items.shuffled().prefix(20) { songs += await tracksOf(album, client: state.client) }
        await playShuffled(songs, on: state.player)
    }
    #endif
}
