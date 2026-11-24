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
        content
            .navigationTitle(artist.name ?? "Artist")
            .task { await load() }
    }

    #if os(macOS)
    @Environment(\.uiScale) private var zoom
    @State private var width: CGFloat = 0

    /// Personality v1, as Flutter's ArtistPage: the round portrait in the big header, your
    /// top songs with About beside them on a wide window, then the albums and similar artists.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxDetailHeader(label: "Artist", title: artist.name ?? "Unknown Artist", artId: artist.id, round: true,
                               meta: macMeta, voice: songs.isEmpty ? nil : macVoice) {
                    PillButton("Play", symbol: "play.fill", primary: true) {
                        Task { await state.player?.play(await allSongs(), startIndex: 0) }
                    }
                    PillButton("Shuffle", symbol: "shuffle") { Task { await playShuffled(await allSongs(), on: state.player) } }
                    CxLikeButton(item: artist)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if width >= 900 {
                        HStack(alignment: .top, spacing: 32) {
                            topSongsColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                            aboutColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        topSongsColumn
                        aboutColumn.padding(.top, 30)
                    }
                    if !albums.isEmpty {
                        CxSectionTitle(title: "Albums")
                        ItemTiles(items: albums)
                    }
                    if !similar.isEmpty {
                        CxSectionTitle(title: "Similar artists")
                        ItemTiles(items: Array(similar.prefix(12)))
                    }
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty, skeleton: .grid)
                }
                .padding(.horizontal, 36 * zoom).padding(.bottom, 40 * zoom)
                .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            }
        }
    }

    @ViewBuilder private var topSongsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CxSectionTitle(title: "Your top songs", top: 0)
            if topSongs.isEmpty {
                Text(isLoading ? " " : "Play something of theirs and it shows here.").cx(.regular).foregroundStyle(Cx.text3)
            }
            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, track in
                CxTrackRow(track: track, number: index + 1, showsArt: true, second: track.album) {
                    Task { await state.player?.play(topSongs, startIndex: index) }
                }
            }
        }
    }

    /// Clamped to six lines with More, as Flutter's.
    @ViewBuilder private var aboutColumn: some View {
        if let overview, !overview.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CxSectionTitle(title: "About", top: 0)
                Text(overview)
                    .cx(.regular).foregroundStyle(Cx.text2).lineSpacing(5)
                    .lineLimit(bioExpanded ? nil : 6)
                if overview.count > 400 {
                    Button(bioExpanded ? "Less" : "More") { withAnimation { bioExpanded.toggle() } }
                        .buttonStyle(.plain).cx(.strong).foregroundStyle(Cx.accent).padding(.top, 6)
                }
            }
        }
    }

    #endif

    /// "9 albums · 112 songs in your library".
    private var macMeta: String {
        guard !isLoading else { return "" }
        return "\(cxCount(albums.count, "album")) \u{00B7} \(cxCount(songs.count, "song")) in your library"
    }

    private var macVoice: String {
        let plays = songs.reduce(0) { $0 + ($1.userData?.playCount ?? 0) }
        return plays == 0 ? "Nothing played yet." : "You\u{2019}ve played their songs \(plays) \(plays == 1 ? "time" : "times")."
    }

    #if os(iOS)
    /// Personality v1 on the phone: the round portrait in the centered header, your top
    /// songs, About, then the albums and similar artists as shelves.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                CxPhoneDetailHeader(title: artist.name ?? "Unknown Artist", artId: artist.id, round: true,
                                    meta: macMeta, voice: songs.isEmpty ? nil : macVoice) {
                    PillButton("Play", symbol: "play.fill", primary: true, wide: true) {
                        Task { await state.player?.play(await allSongs(), startIndex: 0) }
                    }
                    PillButton("Shuffle", symbol: "shuffle", wide: true) { Task { await playShuffled(await allSongs(), on: state.player) } }
                } icons: {
                    CxLikeButton(item: artist)
                }
                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CxShelfTitle(title: "Your top songs")
                        ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, track in
                            CxSongRow(track: track, second: track.album) {
                                Task { await state.player?.play(topSongs, startIndex: index) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if let overview, !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").cx(.section).foregroundStyle(Cx.text)
                        Text(overview).cx(.regular).foregroundStyle(Cx.text2).lineSpacing(4)
                            .lineLimit(bioExpanded ? nil : 5)
                        if overview.count > 240 {
                            Button(bioExpanded ? "Less" : "More") { withAnimation { bioExpanded.toggle() } }
                                .buttonStyle(.plain).cx(.strong).foregroundStyle(Cx.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if !albums.isEmpty {
                    CxShelf(title: "Albums", items: albums) { album in
                        NavigationLink(value: album) {
                            CxCoverTile(itemId: album.id, title: album.name ?? "Unknown", subtitle: album.productionYear.map(String.init))
                        }
                        .buttonStyle(.plain).itemContextMenu(album)
                    }
                }
                if !similar.isEmpty {
                    CxShelf(title: "Similar artists", items: Array(similar.prefix(12))) { other in
                        NavigationLink(value: other) {
                            VStack(spacing: 8) {
                                ArtworkView(itemId: other.id, size: 110).clipShape(Circle())
                                Text(other.name ?? "").cx(.row).foregroundStyle(Cx.text).lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain).itemContextMenu(other)
                    }
                }
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty, skeleton: .grid)
            }
            .padding(.bottom, 24)
        }
        .toolbarTitleDisplayMode(.inline)
    }
    #elseif os(tvOS)
    private var content: some View {
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
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: albums.isEmpty, skeleton: .grid)
            }
        }
    }
    #endif

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
                .scaledFont(.callout)
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
                                Text(other.name ?? "").scaledFont(.caption).lineLimit(1)
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
