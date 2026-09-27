import SwiftUI
import CascadeKit

/// Read-only for now: browse and play. Editing (add, remove, reorder) comes
/// later; the server facts it will need are in the desktop's CODEMAP.
struct PlaylistsView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @AppStorage("cascade.playlists.sort") private var sortField: PlaylistSortField = .name
    @AppStorage("cascade.playlists.order") private var sortDirection: SortDirection = .ascending

    var body: some View {
        ScrollView {
            HStack {
                SortMenu(fields: [(PlaylistSortField.name, "Name"), (.added, "Date Added")],
                         field: $sortField, direction: $sortDirection)
                Spacer()
            }
            .padding(.horizontal)
            .browseHeader()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Playlists")
        .onChange(of: sortField) { sortDirection = sortField.defaultDirection }
        .task(id: BrowseKey(sort: sortField.rawValue, direction: sortDirection)) {
            guard let client = state.client else { return }
            do {
                items = try await client.playlists(sortBy: sortField.serverSortBy,
                                                   sortOrder: sortDirection.serverValue)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            isLoading = false
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: JfItem

    @Environment(AppState.self) private var state
    @State private var tracks: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 12) {
                    ArtworkView(itemId: playlist.id, size: 200)
                    Text(playlist.name ?? "Playlist")
                        .font(.title2.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("\(tracks.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button {
                            RecentPlaylists.touch(playlist.id)
                            Task { await state.player?.play(tracks, startIndex: 0) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button {
                            RecentPlaylists.touch(playlist.id)
                            Task {
                                await state.player?.play(tracks, startIndex: 0)
                                state.player?.toggleShuffle()
                            }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tracks.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding()

                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button {
                        RecentPlaylists.touch(playlist.id)
                        Task { await state.player?.play(tracks, startIndex: index) }
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                }
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty)
                    .padding(.horizontal)
            }
        }
        .navigationTitle(playlist.name ?? "Playlist")
        .task {
            guard let client = state.client else { return }
            do { tracks = try await client.tracks(inPlaylist: playlist.id) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }
}
