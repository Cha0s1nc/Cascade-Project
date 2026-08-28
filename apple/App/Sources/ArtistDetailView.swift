import SwiftUI
import CascadeKit

struct ArtistDetailView: View {
    let artist: JfItem

    @Environment(AppState.self) private var state
    @State private var albums: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selected: JfItem?
    @State private var showDetail = false

    var body: some View {
        ScrollView {
            header
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty)
            ItemGrid(items: albums) { selected = $0; showDetail = true }
        }
        .navigationTitle(artist.name ?? "Artist")
        // JfItem is not Hashable, so navigationDestination(item:) is out;
        // isPresented only needs the Bool.
        .navigationDestination(isPresented: $showDetail) {
            if let selected { AlbumDetailView(album: selected) }
        }
        .task {
            guard let client = state.client else { return }
            do { albums = try await client.albums(byArtist: artist.id) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemId: artist.id, size: 200)
            Text(artist.name ?? "Unknown Artist")
                .font(.title2.bold())
                .lineLimit(1)
            Button {
                Task {
                    guard let client = state.client else { return }
                    do {
                        let tracks = try await client.tracks(byArtist: artist.id)
                        await state.player?.play(tracks, startIndex: 0)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
