import SwiftUI
import CascadeKit

/// The signed-in shell: tabs, and a mini player pinned above them on iOS.
///
/// tvOS gets no mini player. The remote has no room for one, so the player is
/// a Now Playing tab instead, and picking something to play switches to it. Before this the tvOS player could not be
/// reached at all: nothing opened it.
struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var showingNowPlaying = false
    @State private var tab: AppTab = .home

    enum AppTab: Hashable { case nowPlaying, home, albums, artists, songs, playlists, search, settings }

    var body: some View {
        #if os(tvOS)
        tabs
        #else
        VStack(spacing: 0) {
            tabs
            if let player = state.player, player.item != nil {
                MiniPlayer(player: player) { showingNowPlaying = true }
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            if let player = state.player {
                NowPlayingView(player: player)
            }
        }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            #if os(tvOS)
            // Always there rather than added when playback starts: a tab
            // inserted and selected in the same update was never built, and
            // showed an empty screen. Idle, it says "Nothing playing".
            Tab("Now Playing", systemImage: "play.circle", value: AppTab.nowPlaying) {
                if let player = state.player {
                    NowPlayingView(player: player)
                }
            }
            #endif
            Tab("Home", systemImage: "house", value: AppTab.home) { stack { HomeView() } }
            Tab("Albums", systemImage: "square.stack", value: AppTab.albums) { stack { AlbumsView() } }
            Tab("Artists", systemImage: "music.mic", value: AppTab.artists) { stack { ArtistsView() } }
            Tab("Songs", systemImage: "music.note.list", value: AppTab.songs) { stack { SongsView() } }
            Tab("Playlists", systemImage: "music.note.square.stack", value: AppTab.playlists) { stack { PlaylistsView() } }
            #if os(tvOS)
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { stack { SearchView() } }
            Tab("Settings", systemImage: "gear", value: AppTab.settings) { stack { SettingsView() } }
            #endif
        }
        #if os(tvOS)
        .onChange(of: state.player?.playRequests ?? 0) { tab = .nowPlaying }
        #endif
    }

    /// One stack per tab, with the shared routes and (on iOS) the search and
    /// settings buttons.
    private func stack<Content: View>(@ViewBuilder _ root: () -> Content) -> some View {
        NavigationStack {
            root()
                .libraryToolbar()
                .appNavigation()
        }
    }
}

#if !os(tvOS)
/// The always-there strip on iOS. Tapping it opens the full player; the button
/// on it does not, so play/pause never costs a screen transition.
struct MiniPlayer: View {
    let player: PlaybackService
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.item?.name ?? "").font(.callout).lineLimit(1)
                Text(player.item?.albumArtist ?? "").font(.caption2)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title3)
            }
            .buttonStyle(.plain)
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
#endif
