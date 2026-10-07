import SwiftUI
import CascadeKit

/// Every genre in the chosen libraries. Reached from the Albums screen rather
/// than a tab of its own: iOS already has five tabs (a sixth goes into
/// "More"), and the tvOS tab bar already runs past the edge of the screen.
/// Browsing by genre is browsing albums, so it sits next to them. The Mac has
/// it in the sidebar, as tiles.
struct GenresView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        content
            .navigationTitle("Genres")
            .task(id: state.config?.libraryIds) {
                guard let client = state.client else { return }
                do {
                    items = try await client.genres()
                    error = nil
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
                isLoading = false
            }
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        ScrollView {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                ForEach(items) { genre in
                    NavigationLink(value: genre) { GenreTile(name: genre.name ?? "Unknown") }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        #else
        List {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid)
            ForEach(items) { genre in
                NavigationLink(value: genre) {
                    Text(genre.name ?? "Unknown")
                }
            }
        }
        #endif
    }
}

#if os(macOS)
/// A genre as a colored tile. The color comes from the name, so a genre keeps
/// its color from one launch to the next.
private struct GenreTile: View {
    let name: String

    var body: some View {
        // A fixed hash: String.hashValue is seeded per launch.
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(hue: Double(seed) / 360, saturation: 0.55, brightness: 0.75),
                                    Color(hue: Double((seed + 40) % 360) / 360, saturation: 0.6, brightness: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(name)
                .font(.headline)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .lineLimit(2)
                .padding(12)
        }
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
#endif

/// A genre's albums, with Play and Shuffle for all of its songs, and its songs
/// below in chunks of 300 with Show more (the desktop's genre page).
struct GenreDetailView: View {
    let genre: JfItem

    private static let chunk = 300

    @Environment(AppState.self) private var state
    @State private var albums: [JfItem] = []
    @State private var songs: [JfItem] = []
    @State private var moreSongs = false
    @State private var songOffset = 0
    @State private var isLoadingSongs = false
    @State private var isLoading = true
    @State private var error: String?
    @State private var isStarting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    Button { Task { await start(shuffled: false) } } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button { Task { await start(shuffled: true) } } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStarting || albums.isEmpty)
            }
            .padding()
            .browseHeader()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty, skeleton: .grid)
            ItemTiles(items: albums)
            if !songs.isEmpty { songsSection }
        }
        .navigationTitle(genre.name ?? "Genre")
        .task {
            guard let client = state.client else { return }
            async let firstSongs: Void = loadMoreSongs()
            do { albums = try await client.albums(limit: 1000, genreId: genre.id) }
            catch { self.error = error.localizedDescription }
            isLoading = false
            await firstSongs
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Songs").font(.title3.bold()).padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task { await state.player?.play(songs, startIndex: index) }
                    } label: {
                        TrackRow(track: song).padding(.horizontal).padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            if moreSongs {
                Button(isLoadingSongs ? "Loading..." : "Show more") { Task { await loadMoreSongs() } }
                    .disabled(isLoadingSongs)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .padding(.bottom)
    }

    /// The next 300 songs in album order. A short page is the last one, so
    /// "Show more" goes away rather than offering an empty page.
    private func loadMoreSongs() async {
        guard !isLoadingSongs, let client = state.client else { return }
        isLoadingSongs = true
        defer { isLoadingSongs = false }
        // The offset is per library, so it counts chunks asked for, not songs
        // held: with several libraries chosen the two differ.
        guard let page = try? await client.songs(limit: Self.chunk, startIndex: songOffset,
                                                 sortBy: "AlbumArtist,Album,ParentIndexNumber,IndexNumber",
                                                 genreId: genre.id) else { return }
        songOffset += Self.chunk
        let known = Set(songs.map(\.id))
        songs += page.filter { !known.contains($0.id) }
        moreSongs = page.count >= Self.chunk
    }

    /// Songs are fetched on demand rather than with the page: the albums are
    /// what the page shows, and a big genre is thousands of songs.
    private func start(shuffled: Bool) async {
        guard !isStarting, let client = state.client else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            if shuffled {
                await playShuffled(try await client.randomSongs(genreId: genre.id), on: state.player)
            } else {
                let songs = try await client.songs(inGenre: genre.id)
                if !songs.isEmpty { await state.player?.play(songs, startIndex: 0) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
