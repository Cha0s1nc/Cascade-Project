import SwiftUI
import CascadeKit

extension EnvironmentValues {
    /// Opens a library item the way a deep link does: switching the Music /
    /// Video mode if the item belongs to the other one, then going to its
    /// section. Set by the Mac shell; nil elsewhere, where a result is a plain
    /// navigation link on the stack it is in.
    @Entry var showLibraryItem: ((JfItem) -> Void)? = nil
}

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


/// Songs 10, albums 8, artists 8, and movies and shows 8 each from the chosen
/// video libraries, after a 300 ms pause in typing (the desktop's search).
struct SearchResultsView: View {
    let query: String
    /// tvOS has no search field of its own, so the screen carries one.
    var field: Binding<String>?

    @Environment(AppState.self) private var state
    @State private var results = SearchResults()
    @State private var isLoading = false
    @State private var error: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private struct SearchKey: Hashable { var query: String; var movies: [String]; var shows: [String] }

    var body: some View {
        List {
            #if os(tvOS)
            if let field { TextField("Search", text: field) }
            #endif
            if !trimmed.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && results.isEmpty)
            }
            if !results.songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                        Button {
                            Task { await state.player?.play(results.songs, startIndex: index) }
                        } label: {
                            TrackRow(track: song)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            section("Albums", results.albums)
            section("Artists", results.artists, round: true)
            section("Movies", results.movies, poster: true)
            section("Shows", results.shows, poster: true)
        }
        .task(id: SearchKey(query: trimmed, movies: libraries.movieIds, shows: libraries.showIds)) {
            guard !trimmed.isEmpty, let client = state.client else {
                results = SearchResults(); isLoading = false; error = nil
                return
            }
            // Quiet period before firing, and cancellation via .task(id:) itself,
            // is what keeps a per-keystroke request from hammering the server.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            isLoading = true
            await libraries.load(client: client, userId: state.config?.userId)
            do {
                results = try await client.searchEverything(trimmed, movieLibraries: libraries.movieIds,
                                                            showLibraries: libraries.showIds)
                error = nil
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [JfItem], round: Bool = false, poster: Bool = false) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    ResultLink(item: item) {
                        HStack(spacing: 12) {
                            ArtworkView(itemId: item.id, size: poster ? 30 : 40, aspect: poster ? 2.0 / 3.0 : 1)
                                .clipShape(round ? AnyShape(Circle()) : AnyShape(ProportionalRoundedRectangle()))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Unknown").lineLimit(1)
                                if let subtitle = subtitle(item) {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private func subtitle(_ item: JfItem) -> String? {
        switch item.type {
        case "MusicAlbum": item.albumArtist
        case "Movie", "Series": item.productionYear.map(String.init)
        default: nil
        }
    }
}

/// A search result's row: a navigation link on the stack it is shown in, or,
/// where the shell provides showLibraryItem, a deep link that can switch mode.
private struct ResultLink<Label: View>: View {
    let item: JfItem
    @ViewBuilder let label: Label
    @Environment(\.showLibraryItem) private var show

    var body: some View {
        if let show {
            Button { show(item) } label: { label }.buttonStyle(.plain)
        } else {
            NavigationLink(value: item) { label }
        }
    }
}
