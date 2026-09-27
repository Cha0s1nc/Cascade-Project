import SwiftUI
import CascadeKit

/// Every genre in the chosen libraries. Reached from the Albums screen rather
/// than a tab of its own: iOS already has five tabs (a sixth goes into
/// "More"), and the tvOS tab bar already runs past the edge of the screen.
/// Browsing by genre is browsing albums, so it sits next to them.
struct GenresView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        List {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ForEach(items) { genre in
                NavigationLink(value: genre) {
                    Text(genre.name ?? "Unknown")
                }
            }
        }
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
}

/// A genre's albums, with Play and Shuffle for all of its songs.
struct GenreDetailView: View {
    let genre: JfItem

    @Environment(AppState.self) private var state
    @State private var albums: [JfItem] = []
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
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty)
            ItemGrid(items: albums)
        }
        .navigationTitle(genre.name ?? "Genre")
        .task {
            guard let client = state.client else { return }
            do { albums = try await client.albums(limit: 1000, genreId: genre.id) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
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
