import SwiftUI
import CascadeKit

struct SongsView: View {
    @Environment(AppState.self) private var state
    /// Loaded and kept by AppState (see browseList), so it survives leaving
    /// this screen and keeps filling while it is off screen.
    @State private var list: BrowseList?
    private var items: [JfItem] { list?.items ?? [] }
    private var isLoading: Bool { list?.isLoading ?? true }
    private var error: String? { list?.error }
    /// True once every page is in, so Play All and Shuffle All can use the
    /// list on screen instead of asking the server again.
    private var loadedAll: Bool { list?.isComplete ?? false }
    @State private var isStarting = false
    @State private var playError: String?
    @AppStorage("cascade.songs.sort") private var sortField: SongSortField = .name
    @AppStorage("cascade.songs.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.songs.favorites") private var favoritesOnly = false
    /// Bumped by pull to refresh, so the reload misses the cache.
    @State private var refreshes = 0

    private var browseKey: BrowseKey {
        BrowseKey(libraries: state.config?.libraryIds, sort: sortField.rawValue,
                  direction: sortDirection, favoritesOnly: favoritesOnly, generation: refreshes)
    }

    var body: some View {
        List {
            // Two equal-width buttons of their own, like Apple Music's Songs
            // screen; sort lives in the toolbar on iOS (see below).
            HStack(spacing: 12) {
                Button { Task { await playAll(shuffled: false) } } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { Task { await playAll(shuffled: true) } } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            // Bordered, not the List's default, or the List makes the whole
            // row one button and a tap anywhere fires both.
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .fontWeight(.semibold)
            .disabled(isStarting)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
            .browseHeader()
            #if os(tvOS)
            // tvOS shows no toolbar items on these screens, so sort stays in
            // the list there.
            sortMenu
                .browseHeader()
                .buttonStyle(.borderless)
            #endif
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
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        #endif
        .alert("Could not play", isPresented: Binding(get: { playError != nil },
                                                      set: { if !$0 { playError = nil } })) {
            Button("OK") {}
        } message: {
            Text(playError ?? "")
        }
        .onChange(of: sortField) { sortDirection = sortField.defaultDirection }
        .refreshable { state.dropBrowseCache(.songs); refreshes += 1 }
        // The server sorts, not this view. Sorting here (sortSongs) only
        // sorted the pages loaded so far, so the first rows were wrong until
        // the last page landed. sortSongs' plain lowercase compare also
        // disagrees with Jellyfin's SortName collation, so re-sorting the
        // server's pages with it made rows jump as pages arrived.
        .task(id: browseKey) {
            guard let client = state.client else { return }
            let (sortBy, order, favorites) = (sortField.serverSortBy, sortDirection.serverValue, favoritesOnly)
            list = state.browseList(.songs, browseKey) { list in
                try await loadPaged(sortBy: sortBy, sortOrder: order, fetch: {
                    try await client.songs(limit: $0, startIndex: $1, sortBy: sortBy,
                                           sortOrder: order, favoritesOnly: favorites)
                }) {
                    list.items = $0
                    list.isLoading = false
                }
            }
        }
    }

    private var sortMenu: some View {
        SortMenu(fields: [(SongSortField.name, "Title"), (.artist, "Artist"), (.album, "Album"),
                          (.added, "Date Added"), (.played, "Date Last Played")],
                 field: $sortField, direction: $sortDirection, favoritesOnly: $favoritesOnly)
    }

    /// Play All and Shuffle All cover the whole library (in the current sort
    /// and filter), not just the pages loaded so far.
    ///
    /// Once every page is in, that is the list on screen and nothing waits.
    /// Before then, Shuffle asks the server for a random order (one request,
    /// capped at 1,000), and Play fetches every song in one request rather
    /// than paging, which is far quicker than the 200-at-a-time list load.
    /// ponytail: Play still waits for that one full fetch on a big library.
    /// Starting on the first page needs a way to extend the player's queue
    /// afterwards, which PlaybackService does not have yet.
    private func playAll(shuffled: Bool) async {
        guard !isStarting, let client = state.client else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            var list = items
            if !loadedAll {
                list = shuffled
                    ? try await client.randomSongs(favoritesOnly: favoritesOnly)
                    : try await client.songs(limit: nil, sortBy: sortField.serverSortBy,
                                             sortOrder: sortDirection.serverValue, favoritesOnly: favoritesOnly)
            }
            if shuffled {
                await playShuffled(list, on: state.player)
            } else if !list.isEmpty {
                await state.player?.play(list, startIndex: 0)
            }
        } catch {
            playError = error.localizedDescription
        }
    }
}
