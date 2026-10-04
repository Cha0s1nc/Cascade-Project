import SwiftUI
import CascadeKit

/// An artist: play and shuffle everything, their biography, the songs this
/// user plays most, their albums, and similar artists in the selected
/// libraries. The desktop's artist page (renderer.js openArtist).
struct ArtistDetailView: View {
    let artist: JfItem

    @Environment(AppState.self) private var state
    @State private var albums: [JfItem] = []
    @State private var songs: [JfItem] = []
    @State private var similar: [JfItem] = []
    /// The full item: a list's artist carries no biography.
    @State private var overview: String?
    @State private var bioExpanded = false
    @State private var isLoading = true
    @State private var error: String?

    private var topSongs: [JfItem] { ArtistPage.topSongs(songs) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if let overview, !overview.isEmpty { bio(overview) }
                if !topSongs.isEmpty { topSongsSection }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            sectionTitle("Albums")
                            Spacer()
                            // Every album in order, as the desktop's Play All
                            // on the albums section does.
                            Button { Task { await state.player?.play(await allSongs(), startIndex: 0) } } label: {
                                Label("Play All", systemImage: "play.fill")
                            }
                            .padding(.trailing)
                        }
                        ItemTiles(items: albums)
                    }
                }
                if !similar.isEmpty { similarSection }
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty)
            }
        }
        .navigationTitle(artist.name ?? "Artist")
        .task { await load() }
    }

    /// Albums first, since they are the page; the rest fill in as they come,
    /// and each can fail on its own without blanking the page.
    private func load() async {
        guard let client = state.client else { return }
        async let full = try? client.item(id: artist.id)
        async let artistSongs = try? client.tracks(byArtist: artist.id)
        async let similarArtists = try? client.similarArtists(to: artist.id)
        do { albums = try await client.albums(byArtist: artist.id) }
        catch { self.error = error.localizedDescription }
        isLoading = false
        overview = await full?.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        songs = await artistSongs ?? []
        similar = await similarArtists ?? []
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemId: artist.id, size: 200)
            Text(artist.name ?? "Unknown Artist")
                .font(.title2.bold())
                .lineLimit(1)
            HStack(spacing: 12) {
                Button {
                    Task { await state.player?.play(await allSongs(), startIndex: 0) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    Task { await playShuffled(await allSongs(), on: state.player) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top)
    }

    /// The songs already loaded, or fetched if Play beat them in.
    private func allSongs() async -> [JfItem] {
        if !songs.isEmpty { return songs }
        return (try? await state.client?.tracks(byArtist: artist.id)) ?? []
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.title3.bold()).padding(.horizontal)
    }

    /// Clamped to four lines with More, as on the desktop.
    ///
    /// ponytail: More shows by length, not by whether the clamp cut anything;
    /// a 300-character bio on a wide iPad offers More for nothing. Measure
    /// the text if that is ever seen.
    private func bio(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About").font(.title3.bold())
            Text(text)
                .lineLimit(bioExpanded ? nil : 4)
                .font(.callout)
                .foregroundStyle(.secondary)
            if text.count > 240 {
                Button(bioExpanded ? "Less" : "More") { withAnimation { bioExpanded.toggle() } }
                    .font(.callout.weight(.semibold))
            }
        }
        .padding(.horizontal)
    }

    private var topSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Top Songs")
            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, track in
                Button {
                    Task { await state.player?.play(topSongs, startIndex: index) }
                } label: {
                    TrackRow(track: track)
                        .padding(.horizontal)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .trackContextMenu(track)
            }
        }
    }

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Similar Artists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(similar) { other in
                        NavigationLink(value: other) {
                            VStack(spacing: 6) {
                                ArtworkView(itemId: other.id, size: 110)
                                    .clipShape(Circle())
                                Text(other.name ?? "").font(.caption).lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                        .itemContextMenu(other)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom)
    }
}
