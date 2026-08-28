import SwiftUI
import CascadeKit

struct SearchView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var artists: [JfItem] = []
    @State private var albums: [JfItem] = []
    @State private var songs: [JfItem] = []
    @State private var isLoading = false
    @State private var error: String?

    private var trimmed: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool { !artists.isEmpty || !albums.isEmpty || !songs.isEmpty }

    var body: some View {
        List {
            #if os(tvOS)
            TextField("Search", text: $searchText)
            #endif
            if !trimmed.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && !hasResults)
            }
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistDetailView(artist: artist)
                        } label: {
                            Text(artist.name ?? "Unknown")
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            Text(album.name ?? "Unknown")
                        }
                    }
                }
            }
            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            Task { await state.player?.play(songs, startIndex: index) }
                        } label: {
                            TrackRow(track: song)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Search")
        #if !os(tvOS)
        .searchable(text: $searchText)
        #endif
        .task(id: searchText) {
            guard !trimmed.isEmpty, let client = state.client else {
                artists = []; albums = []; songs = []; isLoading = false; error = nil
                return
            }
            // Quiet period before firing, and cancellation via .task(id:) itself,
            // is what keeps a per-keystroke request from hammering the server.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            isLoading = true
            do {
                let results = try await client.search(trimmed)
                artists = results.filter { $0.type == "MusicArtist" }
                albums = results.filter { $0.type == "MusicAlbum" }
                songs = results.filter { $0.type == "Audio" }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
