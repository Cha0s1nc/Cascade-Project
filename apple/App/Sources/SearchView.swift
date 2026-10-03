import SwiftUI
import CascadeKit

struct SearchView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var artists: [JfItem] = []
    @State private var albums: [JfItem] = []
    @State private var songs: [JfItem] = []
    /// Video mode searches films and TV instead of music.
    @State private var movies: [JfItem] = []
    @State private var shows: [JfItem] = []
    @State private var episodes: [JfItem] = []
    @State private var isLoading = false
    @State private var error: String?

    private var trimmed: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isVideo: Bool { state.browseMode == .video }
    private var hasResults: Bool {
        !artists.isEmpty || !albums.isEmpty || !songs.isEmpty || !movies.isEmpty || !shows.isEmpty || !episodes.isEmpty
    }

    var body: some View {
        List {
            #if os(tvOS)
            TextField("Search", text: $searchText)
            #endif
            if !trimmed.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && !hasResults,
                               emptySymbol: isVideo ? "film" : "music.note")
            }
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            Text(artist.name ?? "Unknown")
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            Text(album.name ?? "Unknown")
                        }
                    }
                }
            }
            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { movie in
                        NavigationLink(value: movie) {
                            LabeledContent(movie.name ?? "Unknown", value: movie.productionYear.map(String.init) ?? "")
                        }
                    }
                }
            }
            if !shows.isEmpty {
                Section("Shows") {
                    ForEach(shows) { show in
                        NavigationLink(value: show) {
                            Text(show.name ?? "Unknown")
                        }
                    }
                }
            }
            if !episodes.isEmpty {
                Section("Episodes") {
                    // Plays on through the rest of its season, as a tile does.
                    ForEach(episodes) { episode in
                        Button {
                            Task { await state.playVideoItem(episode) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.name ?? "Unknown")
                                Text([episode.seriesName, VideoPlayback.episodeCode(episode)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
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
        .searchable(text: $searchText, prompt: isVideo ? "Movies, shows and episodes" : "Artists, albums and songs")
        #endif
        .task(id: "\(isVideo)|\(searchText)") {
            artists = []; albums = []; songs = []; movies = []; shows = []; episodes = []
            guard !trimmed.isEmpty, let client = state.client else {
                isLoading = false; error = nil
                return
            }
            // Quiet period before firing, and cancellation via .task(id:) itself,
            // is what keeps a per-keystroke request from hammering the server.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            isLoading = true
            do {
                if isVideo {
                    let results = try await client.searchVideo(trimmed)
                    movies = results.filter { $0.type == "Movie" }
                    shows = results.filter { $0.type == "Series" }
                    episodes = results.filter { $0.type == "Episode" }
                } else {
                    let results = try await client.search(trimmed)
                    artists = results.filter { $0.type == "MusicArtist" }
                    albums = results.filter { $0.type == "MusicAlbum" }
                    songs = results.filter { $0.type == "Audio" }
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
