import SwiftUI
import CascadeKit

/// The signed-in Mac shell: a sidebar of library sections, the section's own
/// navigation stack, and the player bar along the bottom. The desktop app's
/// layout, in place of the phone's tabs and mini player pill.
///
/// The window's size (1100x700 by default, 800x560 at the least) is set where
/// the scene is declared (CascadeApp's defaultSize) and here (the minimum);
/// SwiftUI restores the frame the person left it at.
struct MacRootView: View {
    @Environment(AppState.self) private var state
    @SceneStorage("mac.section") private var section: MacSection = .home
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// Where a deep link wants to go once its section's stack is up.
    @State private var pendingItem: JfItem?

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // The bar sits under the split view, not over it as an inset: the
        // AppKit lists and forms in the columns ignore a SwiftUI inset, so
        // Settings and the sidebar's own Settings row ran under the bar.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                // Keyed by section, so each one starts at its own root rather
                // than inheriting the last section's pushed pages.
                if isSearching {
                    TabStack { SearchResultsView(query: query).navigationTitle("Search") }
                        .id("search")
                } else {
                    TabStack(opening: $pendingItem) { section.root }
                        .id(section)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    // Nothing to switch to on a music-only server, as on the desktop.
                    if libraries.hasVideoLibrary {
                        @Bindable var state = state
                        Picker("Browse", selection: $state.browseMode) {
                            Text("Music").tag(AppState.BrowseMode.music)
                            Text("Video").tag(AppState.BrowseMode.video)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                ToolbarItem(placement: .primaryAction) { MacConnectButtons() }
                ToolbarItem(placement: .primaryAction) { ThemePanelButton() }
            }
            .searchable(text: $query, placement: .toolbar,
                        prompt: state.browseMode == .video ? "Search movies and shows" : "Search songs, albums, artists")
            .searchFocused($searchFocused)
            .background {
                // Command-K, as on the desktop. A zero-size button rather than a
                // menu command: the main window is the only place it applies.
                Button("Search") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
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
        // Results, and anything else that opens an item, go through here so a
        // movie found from Music mode switches to Video, as the desktop's
        // sectionMode does for a deep link.
        .environment(\.showLibraryItem) { show($0) }
        .task(id: state.config?.userId) {
            await libraries.load(client: state.client, userId: state.config?.userId)
        }
        // Command-comma and the app menu's Settings come here: one Settings,
        // the sidebar's, rather than a second window with the same tabs.
        .onChange(of: state.settingsRequests) { section = .settings; query = "" }
        // Leaving a mode strands a section only that mode has; Home and
        // Settings are in both, so they stay.
        .onChange(of: state.browseMode) {
            if section != .settings, !MacSection.sidebar(for: state.browseMode).contains(section) { section = .home }
        }
        .frame(minWidth: 800, minHeight: 560)
        #if DEBUG
        // Debug builds only: `-cascade.section songs` opens a section at
        // launch, to check it without clicking (UI scripting is not allowed).
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "cascade.section"), let s = MacSection(rawValue: raw) { section = s }
            // `-cascade.nowPlaying YES` opens Now Playing (paused on a restored queue: nothing plays).
            if UserDefaults.standard.bool(forKey: "cascade.nowPlaying") { state.nowPlayingOpen = true }
        }
        #endif
    }

    private var sidebar: some View {
        List(selection: Binding(get: { section }, set: { section = $0 ?? .home; query = "" })) {
            ForEach(visibleSections) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pinned under the list so it is always there, like the desktop's.
            VStack(spacing: 0) {
                Divider()
                Button { section = .settings; query = "" } label: {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(section == .settings ? Color.accentColor.opacity(0.22) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    /// The sidebar's rows for the mode. Movies and TV Shows only once a
    /// library of that kind exists (or before the server has been asked), so a
    /// row never leads to a screen that cannot have anything on it.
    private var visibleSections: [MacSection] {
        MacSection.sidebar(for: state.browseMode).filter {
            switch $0 {
            case .movies: !libraries.isLoaded || !libraries.movieLibraries.isEmpty
            case .shows: !libraries.isLoaded || !libraries.showLibraries.isEmpty
            // Opted in and allowed Live TV; otherwise the row only leads to
            // a 403 or a prompt nobody asked for. Settings turns it on.
            case .radio: state.showsRadio
            default: true
            }
        }
    }

    /// Opens an item in the section its type belongs to, switching the
    /// Music / Video mode first when that section is the other mode's.
    private func show(_ item: JfItem) {
        guard let name = BrowseModeLogic.section(forItemType: item.type),
              let target = MacSection(rawValue: name) else { return }
        if let mode = BrowseModeLogic.sectionMode(name), mode.rawValue != state.browseMode.rawValue {
            state.browseMode = AppState.BrowseMode(rawValue: mode.rawValue) ?? state.browseMode
        }
        query = ""
        section = target
        pendingItem = item
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
