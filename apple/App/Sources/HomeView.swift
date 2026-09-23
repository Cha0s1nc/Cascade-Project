import SwiftUI
import CascadeKit

/// Three horizontal rows. Recently Played and Frequently Played are empty
/// until the user has actually played something, so a row with no items
/// hides itself instead of showing a heading over nothing.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var recentAlbums: [JfItem] = []
    @State private var recentTracks: [JfItem] = []
    @State private var frequentTracks: [JfItem] = []
    @State private var playlists: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    private var isEmpty: Bool {
        recentAlbums.isEmpty && recentTracks.isEmpty && frequentTracks.isEmpty && playlists.isEmpty
    }

    var body: some View {
        ScrollView {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: isEmpty)
            VStack(alignment: .leading, spacing: 24) {
                if !recentAlbums.isEmpty {
                    row("Recently Added", albums: recentAlbums)
                }
                if !recentTracks.isEmpty {
                    row("Recently Played", tracks: recentTracks)
                }
                if !playlists.isEmpty {
                    // "Recent" only once something has been played from one;
                    // until then it is simply the user's playlists.
                    row(RecentPlaylists.ids.isEmpty ? "Playlists" : "Recent Playlists", albums: playlists)
                }
                if !frequentTracks.isEmpty {
                    row("Frequently Played", tracks: frequentTracks)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        // Keyed on the library selection, so changing it in Settings reloads.
        .task(id: state.config?.libraryIds) {
            guard let client = state.client else { return }
            isLoading = true
            do {
                async let added = client.recentlyAdded()
                async let played = client.recentlyPlayed()
                async let frequent = client.frequentlyPlayed()
                // Playlists are optional here: a failure hides the row rather
                // than the whole screen.
                async let lists = try? client.playlists()
                (recentAlbums, recentTracks, frequentTracks) = try await (added, played, frequent)
                playlists = Array(RecentPlaylists.ordered(await lists ?? []).prefix(12))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func row(_ title: String, albums: [JfItem]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(itemId: album.id, size: 150)
                                Text(album.name ?? "Unknown").font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // Tapping a track plays this row's list starting from that track, per the
    // brief: it is a queue, not a single song.
    private func row(_ title: String, tracks: [JfItem]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            Task { await state.player?.play(tracks, startIndex: index) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(itemId: track.albumId ?? track.id, size: 150)
                                Text(track.name ?? "Unknown").font(.caption).lineLimit(1)
                                Text(track.albumArtist ?? track.artists?.first ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
