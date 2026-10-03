import SwiftUI
import CascadeKit

/// The signed-in Mac shell: a sidebar of library sections, the section's own
/// navigation stack, and the player bar along the bottom. The desktop app's
/// layout, in place of the phone's tabs and mini player pill.
struct MacRootView: View {
    @Environment(AppState.self) private var state
    @SceneStorage("mac.section") private var section: MacSection = .home

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { section = $0 ?? .home })) {
                ForEach(MacSection.sidebar(for: state.browseMode)) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                List(selection: Binding(get: { section }, set: { section = $0 ?? .home })) {
                    Label("Settings", systemImage: "gear").tag(MacSection.settings)
                }
                .frame(height: 44)
                .scrollDisabled(true)
            }
        } detail: {
            // Keyed by section, so each one starts at its own root rather
            // than inheriting the last section's pushed pages.
            TabStack { section.root }
                .id(section)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ThemePanelButton() }
            ToolbarItem(placement: .navigation) {
                @Bindable var state = state
                Picker("Browse", selection: $state.browseMode) {
                    Text("Music").tag(AppState.BrowseMode.music)
                    Text("Video").tag(AppState.BrowseMode.video)
                }
                .pickerStyle(.segmented)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let player = state.player {
                PlayerBar(player: player)
            }
        }
        .overlay {
            // Full-window layers over the split view and the player bar: Now Playing, then a
            // video above everything.
            NowPlayingOverlay()
            MacVideoHost()
        }
        .onChange(of: state.browseMode) { section = .home }
        .frame(minWidth: 800, minHeight: 560)
    }
}

enum MacSection: String, Hashable, Identifiable, CaseIterable {
    case home, albums, artists, songs, playlists, genres, history, radio, movies, shows, settings

    var id: Self { self }

    static func sidebar(for mode: AppState.BrowseMode) -> [MacSection] {
        mode == .video ? [.home, .movies, .shows] : [.home, .albums, .artists, .songs, .playlists, .genres, .history, .radio]
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        case .playlists: "Playlists"
        case .genres: "Genres"
        case .history: "History"
        case .radio: "Radio"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .songs: "music.note.list"
        case .playlists: "music.note.square.stack"
        case .genres: "guitars"
        case .history: "clock"
        case .radio: "dot.radiowaves.left.and.right"
        case .movies: "film"
        case .shows: "tv"
        case .settings: "gear"
        }
    }

    @MainActor @ViewBuilder var root: some View {
        switch self {
        case .home: HomeOrVideoHome()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .songs: SongsView()
        case .playlists: PlaylistsView()
        case .genres: GenresView()
        case .history: HistoryView()
        case .radio: RadioView()
        case .movies: VideoGridView(kind: .movies)
        case .shows: VideoGridView(kind: .shows)
        case .settings: SettingsView()
        }
    }
}

private struct HomeOrVideoHome: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if state.browseMode == .video { VideoHomeView() } else { HomeView() }
    }
}
