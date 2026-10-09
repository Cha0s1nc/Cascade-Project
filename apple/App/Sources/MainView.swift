import SwiftUI
import CascadeKit

// The Mac has its own shell (App/Mac/MacRootView.swift): a sidebar and a
// player bar, not tabs and a pill.
#if !os(macOS)
/// The signed-in shell: tabs, and on iOS the mini player as Apple Music's glass
/// pill over the tab bar.
///
/// tvOS gets no mini player. The remote has no room for one, so the player is
/// a Now Playing tab instead, and picking something to play switches to it. Before this the tvOS player could not be
/// reached at all: nothing opened it.
struct MainView: View {
    @Environment(AppState.self) private var state
    @State private var showingNowPlaying = false
    @State private var tab: AppTab = .home

    enum AppTab: Hashable { case nowPlaying, home, albums, artists, songs, playlists, movies, shows, search, settings }

    var body: some View {
        content
            .fullScreenCover(isPresented: Binding(
                get: { state.videoSession != nil },
                set: { if !$0 { state.closeVideo() } })) {
                if let session = state.videoSession { VideoScreen(session: session) }
            }
            .onChange(of: state.browseMode) { tab = .home }
            .alert("Waterfall", isPresented: Binding(
                get: { state.waterfall?.notice != nil },
                set: { if !$0 { state.waterfall?.notice = nil } })) {
                Button("OK") { state.waterfall?.notice = nil }
            } message: {
                Text(state.waterfall?.notice ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tabs
        #else
        tabsWithPlayer
        .phoneSetup()
        .sheet(isPresented: $showingNowPlaying) {
            if let player = state.player {
                NowPlayingView(player: player)
                    .presentationDragIndicator(.visible)
                    // Solid, so the sheet's default glass does not show the
                    // library through the album-art background.
                    .presentationBackground(.black)
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
            if state.browseMode == .video {
                Tab("Home", systemImage: "house", value: AppTab.home) { stack { VideoHomeView() } }
                Tab("Movies", systemImage: "film", value: AppTab.movies) { stack { VideoGridView(kind: .movies) } }
                Tab("Shows", systemImage: "tv", value: AppTab.shows) { stack { VideoGridView(kind: .shows) } }
            } else {
                Tab("Home", systemImage: "house", value: AppTab.home) { stack { HomeView() } }
                Tab("Albums", systemImage: "square.stack", value: AppTab.albums) { stack { AlbumsView() } }
                Tab("Artists", systemImage: "music.mic", value: AppTab.artists) { stack { ArtistsView() } }
                Tab("Songs", systemImage: "music.note.list", value: AppTab.songs) { stack { SongsView() } }
                Tab("Playlists", systemImage: "music.note.square.stack", value: AppTab.playlists) { stack { PlaylistsView() } }
            }
            #if os(tvOS)
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { stack { SearchView() } }
            Tab("Settings", systemImage: "gear", value: AppTab.settings) { stack { SettingsView() } }
            #endif
        }
        #if os(tvOS)
        .onChange(of: state.player?.playRequests ?? 0) { tab = .nowPlaying }
        #endif
    }

    #if !os(tvOS)
    /// The mini player as the tab view's bottom accessory: the glass pill that
    /// sits over the tab bar and folds in beside it when the tab bar shrinks on
    /// scroll, as in Apple Music. isEnabled needs iOS 26.1 (without it the
    /// pill shows empty when nothing plays); older systems keep the bar under
    /// the tabs.
    @ViewBuilder private var tabsWithPlayer: some View {
        let player = state.player
        if #available(iOS 26.1, *) {
            tabs
                .tabViewBottomAccessory(isEnabled: player?.item != nil) {
                    if let player {
                        AccessoryMiniPlayer(player: player) { showingNowPlaying = true }
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            VStack(spacing: 0) {
                tabs
                if let player, player.item != nil {
                    MiniPlayer(player: player, style: .bar) { showingNowPlaying = true }
                }
            }
        }
    }
    #endif

    /// One stack per tab, with the shared routes and (on iOS) the search and
    /// settings buttons.
    private func stack<Content: View>(@ViewBuilder _ root: () -> Content) -> some View {
        TabStack { root() }
    }
}

#if !os(tvOS)
/// The pill's contents follow where the system has put it: full width over the
/// tab bar, or squeezed inline beside a minimized tab bar.
@available(iOS 26.0, *)
private struct AccessoryMiniPlayer: View {
    let player: PlaybackService
    let onTap: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayer(player: player, style: placement == .inline ? .inline : .pill, onTap: onTap)
    }
}

/// What is playing, always one tap from the full player. Tapping it opens Now
/// Playing; its buttons do not, so play/pause never costs a screen transition.
struct MiniPlayer: View {
    enum Style {
        /// In the glass pill over the tab bar, which draws its own background.
        case pill
        /// The pill folded in beside a minimized tab bar: no room for next.
        case inline
        /// The bar under the tabs, before iOS 26.1.
        case bar
    }

    let player: PlaybackService
    var style: Style = .bar
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: style == .bar ? 12 : 10) {
            ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: style == .bar ? 40 : 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.item?.name ?? "")
                    .font(style == .bar ? .callout : .subheadline.weight(.medium))
                    .lineLimit(1)
                if style != .inline {
                    Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            if style != .inline {
                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }
        }
        .padding(.horizontal, style == .bar ? 16 : 12)
        .padding(.vertical, style == .bar ? 8 : 0)
        .background {
            if style == .bar { Rectangle().fill(.regularMaterial) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing", onTap)
    }
}
#endif
#endif
