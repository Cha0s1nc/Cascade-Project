import SwiftUI
import CascadeKit

/// Horizontal rows: Recently Played and Recently Added (24 each), recent
/// playlists and Frequently Played. A row with nothing in it (no plays yet)
/// hides itself instead of showing a heading over nothing. In Video mode the
/// shell shows VideoHomeView instead, so these music shelves are hidden.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var recentAlbums: [JfItem] = []
    @State private var recentTracks: [JfItem] = []
    @State private var frequentTracks: [JfItem] = []
    @State private var playlists: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    /// View > Zoom on the Mac: the art grows with it, so its slot must too or the tiles overlap.
    @Environment(\.uiScale) private var uiScale
    private var tile: CGFloat { 150 * uiScale }

    private var isEmpty: Bool {
        recentAlbums.isEmpty && recentTracks.isEmpty && frequentTracks.isEmpty && playlists.isEmpty
    }

    var body: some View {
        #if os(iOS)
        phoneBody
        #else
        classicBody
        #endif
    }

    private var classicBody: some View {
        ScrollView {
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: isEmpty, emptySymbol: "house", skeleton: .grid,
                           emptyTitle: "Nothing yet",
                           emptyMessage: "What you play and what is added to the library shows up here.",
                           retry: { Task { await load() } })
            VStack(alignment: .leading, spacing: 24) {
                #if os(macOS)
                GreetingHeader()
                #elseif os(tvOS)
                AnnouncementsButton().padding(.horizontal)
                #endif
                // The desktop's order: what you played, then what is new.
                if !recentTracks.isEmpty {
                    row("Recently Played", tracks: recentTracks, more: .history)
                }
                if !recentAlbums.isEmpty {
                    row("Recently Added", albums: recentAlbums)
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
        .refreshable { await load() }
        // Keyed on the library selection, so changing it in Settings reloads.
        .task(id: state.config?.libraryIds) { await load() }
    }

    #if os(iOS)
    @State private var voice: String?

    /// Penpot "iPhone / Home": the date, the greeting and its voice line, what is playing
    /// as a card, what was played as rows, then the shelves.
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).cx(.caps).foregroundStyle(Cx.text3)
                    Text(greeting).cx(.hero).foregroundStyle(Cx.text)
                    if let voice { Text(voice).cx(.voice).foregroundStyle(Cx.text2) }
                }
                .padding(.horizontal, 16)
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: isEmpty, emptySymbol: "house", skeleton: .grid,
                               emptyTitle: "Nothing yet",
                               emptyMessage: "What you play and what is added to the library shows up here.",
                               retry: { Task { await load() } })
                if let player = state.player, player.item != nil {
                    NowPlayingCard(player: player).padding(.horizontal, 16)
                }
                if !recentTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CxShelfTitle(title: "Recently played", more: .history)
                        ForEach(Array(recentTracks.prefix(5).enumerated()), id: \.element.id) { index, track in
                            CxSongRow(track: track, second: [track.songArtist, track.album ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")) {
                                Task { await state.player?.play(recentTracks, startIndex: index) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if !recentAlbums.isEmpty {
                    CxShelf(title: "Recently added", items: recentAlbums) { album in
                        NavigationLink(value: album) { CxCoverTile(itemId: album.id, title: album.name ?? "Unknown", subtitle: album.albumArtistLine) }
                            .buttonStyle(.plain).itemContextMenu(album)
                    }
                }
                if !playlists.isEmpty {
                    CxShelf(title: RecentPlaylists.ids.isEmpty ? "Playlists" : "Recent playlists", more: .playlists, items: playlists) { list in
                        NavigationLink(value: list) { CxCoverTile(itemId: list.id, title: list.name ?? "Playlist") }
                            .buttonStyle(.plain).itemContextMenu(list)
                    }
                }
                if !frequentTracks.isEmpty {
                    CxShelf(title: "Frequently played", items: Array(frequentTracks.enumerated()).map(IndexedItem.init)) { entry in
                        Button { Task { await state.player?.play(frequentTracks, startIndex: entry.index) } } label: {
                            CxCoverTile(itemId: entry.item.albumId ?? entry.item.id, title: entry.item.name ?? "Unknown", subtitle: entry.item.songArtist)
                        }
                        .buttonStyle(.plain).trackContextMenu(entry.item)
                    }
                }
            }
            .padding(.top, 8).padding(.bottom, 24)
        }
        // The page draws its own greeting; the bar keeps "Home" for the Back button.
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("") } }
        .refreshable { await load() }
        .task(id: state.config?.libraryIds) {
            await load()
            if let stats = try? await state.client?.homeStats() { voice = HomeVoice.line(songs: stats.songs, week: stats.week) }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(state.username ?? "there")"
    }

    private struct IndexedItem: Identifiable {
        let index: Int
        let item: JfItem
        var id: String { "\(index)-\(item.id)" }
        init(_ pair: (offset: Int, element: JfItem)) { index = pair.offset; item = pair.element }
    }
    #endif

    private func load() async {
        guard let client = state.client else { return }
        state.snapshotHistory()
        // Not on a pull to refresh: the shelves stay up while it reloads.
        if isEmpty { isLoading = true }
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

    private func row(_ title: String, albums: [JfItem]) -> some View {
        VStack(alignment: .leading) {
            Text(title).scaledFont(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(itemId: album.id, size: 150)
                                Text(album.name ?? "Unknown").scaledFont(.caption).lineLimit(1)
                            }
                            // Pinned to the art: a horizontal ScrollView offers
                            // its children unlimited width, so lineLimit(1)
                            // never truncated and a long title widened its
                            // whole tile, leaving a gap in the shelf.
                            .frame(width: tile, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .itemContextMenu(album)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // Tapping a track plays this row's list starting from that track, per the
    // brief: it is a queue, not a single song.
    /// `more` is where the row's full list lives (Recently Played's is History).
    private func row(_ title: String, tracks: [JfItem], more: AppRoute? = nil) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title).scaledFont(.headline)
                Spacer()
                if let more {
                    NavigationLink("See All", value: more).scaledFont(.callout)
                }
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            Task { await state.player?.play(tracks, startIndex: index) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(itemId: track.albumId ?? track.id, size: 150)
                                Text(track.name ?? "Unknown").scaledFont(.caption).lineLimit(1)
                                Text(track.albumArtist ?? track.artists?.first ?? "")
                                    .scaledFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: tile, alignment: .leading)   // see the album row
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(track)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
