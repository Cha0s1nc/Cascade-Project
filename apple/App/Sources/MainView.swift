import SwiftUI
import CascadeKit

/// The signed-in shell: tabs, and a mini player pinned above them on iOS.
///
/// tvOS gets no mini player. The remote has no room for one and the platform
/// convention is a full screen player you push to, so the tab bar is the only
/// persistent chrome there.
struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var showingNowPlaying = false

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
        TabView {
            Tab("Home", systemImage: "house") { stack { HomeView() } }
            Tab("Albums", systemImage: "square.stack") { stack { AlbumsView() } }
            Tab("Artists", systemImage: "music.mic") { stack { ArtistsView() } }
            Tab("Songs", systemImage: "music.note.list") { stack { SongsView() } }
            Tab("Playlists", systemImage: "music.note.square.stack") { stack { PlaylistsView() } }
            #if os(tvOS)
            Tab("Search", systemImage: "magnifyingglass", role: .search) { stack { SearchView() } }
            Tab("Settings", systemImage: "gear") { stack { SettingsView() } }
            #endif
        }
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
