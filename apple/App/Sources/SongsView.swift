import SwiftUI
import CascadeKit

struct SongsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    /// True once every page is in, so Play All and Shuffle All can use the
    /// list on screen instead of asking the server again.
    @State private var loadedAll = false
    @State private var isStarting = false
    @State private var playError: String?
    @AppStorage("cascade.songs.sort") private var sortField: SongSortField = .name
    @AppStorage("cascade.songs.order") private var sortDirection: SortDirection = .ascending
    @AppStorage("cascade.songs.favorites") private var favoritesOnly = false

    var body: some View {
        List {
            HStack(spacing: 20) {
                Button { Task { await playAll(shuffled: false) } } label: {
                    Label("Play All", systemImage: "play.fill").labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                }
                Button { Task { await playAll(shuffled: true) } } label: {
                    Label("Shuffle", systemImage: "shuffle").labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                }
                Spacer()
                SortMenu(fields: [(SongSortField.name, "Title"), (.artist, "Artist"), (.album, "Album"),
                                  (.added, "Date Added"), (.played, "Date Last Played")],
                         field: $sortField, direction: $sortDirection, favoritesOnly: $favoritesOnly)
            }
            .disabled(isStarting)
            .browseHeader()
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
        .alert("Could not play", isPresented: Binding(get: { playError != nil },
                                                      set: { if !$0 { playError = nil } })) {
            Button("OK") {}
        } message: {
            Text(playError ?? "")
        }
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
            loadedAll = false
            let (sortBy, order, favorites) = (sortField.serverSortBy, sortDirection.serverValue, favoritesOnly)
            do {
                try await loadPaged(sortBy: sortBy, sortOrder: order, fetch: {
                    try await client.songs(limit: $0, startIndex: $1, sortBy: sortBy,
                                           sortOrder: order, favoritesOnly: favorites)
                }) {
                    items = $0
                    isLoading = false
                }
                // loadPaged returns quietly when cancelled, with a partial list.
                loadedAll = !Task.isCancelled
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            if !Task.isCancelled { isLoading = false }
        }
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
