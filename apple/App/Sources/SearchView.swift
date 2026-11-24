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
        results
        .navigationTitle("Search")
        #if !os(tvOS)
        .searchable(text: $searchText, prompt: isVideo ? "Movies, shows and episodes" : "Artists, albums and songs")
        #endif
        .task(id: "\(isVideo)|\(searchText)") { await search() }
    }

    #if os(iOS)
    enum Filter: String, CaseIterable { case all = "All", songs = "Songs", albums = "Albums", artists = "Artists" }
    @State private var filter: Filter = .all

    private func include(_ f: Filter) -> Bool { filter == .all || filter == f }

    /// Personality v1, as the Penpot "iPhone / Search" board: chips to narrow it, the top
    /// result as a card, songs as rows, then artists and albums as shelves.
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !isVideo && hasResults {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases, id: \.self) { f in CxChip(title: f.rawValue, on: filter == f) { filter = f } }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if !trimmed.isEmpty {
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && !hasResults,
                                   emptySymbol: isVideo ? "film" : "music.note", skeleton: .rows)
                }
                if filter == .all, let top = artists.first ?? albums.first {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top result").cx(.caps).foregroundStyle(Cx.text3).padding(.horizontal, 16)
                        TopResultCard(item: top).padding(.horizontal, 16)
                    }
                }
                if include(.songs) && !songs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CxShelfTitle(title: "Songs")
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            CxSongRow(track: song, second: [song.songArtist, song.album ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")) {
                                Task { await state.player?.play(songs, startIndex: index) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if include(.artists) && !artists.isEmpty {
                    CxShelf(title: "Artists", items: artists) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 8) {
                                ArtworkView(itemId: artist.id, size: 110).clipShape(Circle())
                                Text(artist.name ?? "").cx(.row).foregroundStyle(Cx.text).lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain).itemContextMenu(artist)
                    }
                }
                if include(.albums) && !albums.isEmpty {
                    CxShelf(title: "Albums", items: albums) { album in
                        NavigationLink(value: album) { CxCoverTile(itemId: album.id, title: album.name ?? "Unknown", subtitle: album.albumArtistLine) }
                            .buttonStyle(.plain).itemContextMenu(album)
                    }
                }
                if !movies.isEmpty {
                    CxShelf(title: "Movies", items: movies) { movie in
                        NavigationLink(value: movie) { posterTile(movie) }.buttonStyle(.plain)
                    }
                }
                if !shows.isEmpty {
                    CxShelf(title: "TV shows", items: shows) { show in
                        NavigationLink(value: show) { posterTile(show) }.buttonStyle(.plain)
                    }
                }
                if !episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CxShelfTitle(title: "Episodes")
                        ForEach(episodes) { episode in
                            Button { Task { await state.playVideoItem(episode) } } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(episode.name ?? "Unknown").cx(.row).foregroundStyle(Cx.text)
                                    Text([episode.seriesName, VideoPlayback.episodeCode(episode)].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                        .cx(.small).foregroundStyle(Cx.text2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func posterTile(_ item: JfItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(itemId: item.id, size: 110, aspect: 2.0 / 3.0)
            Text(item.name ?? "Untitled").cx(.row).foregroundStyle(Cx.text).lineLimit(1).padding(.top, 8)
            if let year = item.productionYear { Text(String(year)).cx(.small).foregroundStyle(Cx.text3) }
        }
        .frame(width: 110, alignment: .leading)
    }
    #else
    private var results: some View {
        List {
            #if os(tvOS)
            TextField("Search", text: $searchText)
            #endif
            if !trimmed.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && !hasResults,
                               emptySymbol: isVideo ? "film" : "music.note", skeleton: .rows)
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
                                    .scaledFont(.caption)
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
    }
    #endif

    private func search() async {
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

#if os(iOS)
/// The search's top result (Penpot "iPhone / Search"): the art (round for an artist), the
/// name, what it is, and a play button in the accent.
private struct TopResultCard: View {
    let item: JfItem
    @Environment(AppState.self) private var state

    var body: some View {
        let isArtist = item.type == "MusicArtist"
        NavigationLink(value: item) {
            HStack(spacing: 16) {
                ArtworkView(itemId: item.id, size: 72).clipShape(isArtist ? AnyShape(Circle()) : AnyShape(Rectangle()))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? "Unknown").font(.display(21)).foregroundStyle(Cx.text).lineLimit(1)
                    Text(isArtist ? "Artist" : ["Album", item.albumArtistLine].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { Task { await state.player?.play(await tracksOf(item, client: state.client)) } } label: {
                    Image(systemName: "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(Cx.ink)
                        .frame(width: 44, height: 44).background(Cx.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play")
            }
            .padding(16)
            .background(Cx.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Cx.line))
        }
        .buttonStyle(.plain)
    }
}
#endif


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
        #if os(macOS)
        macBody.task(id: searchKey) { await search() }
        #else
        listBody.task(id: searchKey) { await search() }
        #endif
    }

    private var searchKey: SearchKey { SearchKey(query: trimmed, movies: libraries.movieIds, shows: libraries.showIds) }

    #if os(macOS)
    /// Personality v1, as Flutter's SearchPage: the page header, the songs in the album page's
    /// rows, then artists, albums, movies and shows as cards.
    private var macBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CxPageHeader(title: "Search", voice: trimmed.isEmpty
                             ? "Type in the bar above. Songs, albums, artists, movies and shows."
                             : "Results for \u{201C}\(trimmed)\u{201D}") {} below: {}
                if !trimmed.isEmpty {
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && results.isEmpty, skeleton: .rows,
                                   emptyTitle: "No results for \u{201C}\(trimmed)\u{201D}")
                }
                if !results.songs.isEmpty {
                    CxSectionTitle(title: "Songs", top: 0)
                    ForEach(Array(results.songs.enumerated()), id: \.element.id) { index, song in
                        CxTrackRow(track: song, number: index + 1, showsArt: true,
                                   second: [song.albumArtist ?? song.artists?.first, song.album]
                                       .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")) {
                            Task { await state.player?.play(results.songs, startIndex: index) }
                        }
                    }
                }
                if !results.artists.isEmpty { CxSectionTitle(title: "Artists"); ItemTiles(items: results.artists) }
                if !results.albums.isEmpty { CxSectionTitle(title: "Albums"); ItemTiles(items: results.albums) }
                posters("Movies", results.movies)
                posters("TV Shows", results.shows)
            }
            .cxPage()
        }
    }

    @ViewBuilder private func posters(_ title: String, _ items: [JfItem]) -> some View {
        if !items.isEmpty {
            CxSectionTitle(title: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 16)], alignment: .leading, spacing: 20) {
                // Through the shell, which switches to the video side as it opens one.
                ForEach(items) { item in ResultLink(item: item) { MacPosterTile(item: item) } }
            }
        }
    }
    #endif

    private func search() async {
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

    private var listBody: some View {
        List {
            #if os(tvOS)
            if let field { TextField("Search", text: field) }
            #endif
            if !trimmed.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: !isLoading && results.isEmpty, skeleton: .rows)
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
                                    Text(subtitle).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
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
