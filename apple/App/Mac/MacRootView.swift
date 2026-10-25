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
    /// Where a deep link wants to go, and the section it belongs to.
    @State private var pending: (section: MacSection, item: JfItem)?
    /// View > Zoom (MacZoom).
    @AppStorage(MacZoom.key) private var zoom = 1.0

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // The bar sits under the split view, not over it as an inset: the
        // AppKit lists and forms in the columns ignore a SwiftUI inset, so
        // Settings and the sidebar's own Settings row ran under the bar.
        VStack(spacing: 0) {
            OfflineBanner()
            HStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } detail: {
                // Keyed by section, so each one starts at its own root rather
                // than inheriting the last section's pushed pages.
                if isSearching {
                    TabStack { SearchResultsView(query: query).navigationTitle("Search") }
                        .id("search")
                        .transition(.opacity)
                } else {
                    // Only the target section's stack sees the item. The section is
                    // scene storage, which can update a beat after the item: the
                    // outgoing stack used to take it, and the new one sat on its root.
                    TabStack(opening: Binding(
                        get: { pending?.section == section ? pending?.item : nil },
                        set: { if $0 == nil { pending = nil } })) {
                            // Rebuilt (so reloaded) when the library changes underneath it: Settings >
                            // Refresh, a metadata edit, a delete. Pages pushed on top stay put.
                            section.root.id(state.libraryRevision)
                        }
                        .id(section)
                        .transition(.opacity)
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
                ToolbarItem(placement: .primaryAction) {
                    // Offline, it opens Downloads; Waterfall and other devices
                    // both need the server.
                    if state.isOffline {
                        Button { section = .downloads; query = "" } label: { OfflinePill() }
                            .buttonStyle(.plain)
                    } else {
                        MacConnectButtons()
                    }
                }
                ToolbarItem(placement: .primaryAction) { ThemePanelButton() }
                // In the middle of the bar, as on the desktop. A field of its own: .searchable
                // with .toolbarPrincipal was sent to the overflow menu with Songs' sort and
                // filter buttons in the bar.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(state.browseMode == .video ? "Search movies and shows" : "Search songs, albums, artists",
                                  text: $query)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onExitCommand { query = ""; searchFocused = false }
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    // Grows with View > Zoom, so the zoomed placeholder is not cut off.
                    .frame(width: 280 * min(zoom, 1.5))
                }
            }
            .background {
                // Command-K, as on the desktop. A zero-size button rather than a
                // menu command: the main window is the only place it applies.
                Button("Search") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            // The side lyrics, as a full-height column that pushes the library over instead of
            // a panel floating over it. A column of its own: .inspector threw inside AppKit's
            // layout on macOS 27, on the split view and on its detail column alike.
            if MacNowPlayingUI.shared.sidePanelOpen, let player = state.player {
                Divider()
                SideLyricsPanel(player: player)
                    .transition(.move(edge: .trailing))
            }
            }
            .animation(.easeInOut(duration: 0.25), value: MacNowPlayingUI.shared.sidePanelOpen)
            if let player = state.player {
                PlayerBar(player: player)
            }
        }
        // Over the library's bottom corner, just above the player bar.
        .overlay(alignment: .bottomTrailing) {
            if let offer = state.restoreOffer, !state.nowPlayingOpen {
                RestoreQueueCard(offer: offer)
                    .padding(.trailing, 16)
                    .padding(.bottom, 76)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.restoreOffer?.id)
        // A short crossfade between sidebar sections and in and out of search, where the
        // page used to swap in a single frame.
        .animation(.easeOut(duration: 0.18), value: section)
        .animation(.easeOut(duration: 0.18), value: isSearching)
        .overlay {
            // Full-window layers over the split view and the player bar: Now Playing, then a
            // video above everything.
            NowPlayingOverlay()
            MacVideoHost()
        }
        // A message from the server's admin, over all of it.
        .serverMessages()
        // The one presenter for every track and tile menu in the window:
        // Add to Playlist, Media Info, the delete dialogs.
        .trackActionHost()
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
            if !MacSection.pinned.contains(section), !MacSection.sidebar(for: state.browseMode).contains(section) { section = .home }
        }
        .frame(minWidth: 800, minHeight: 560)
        // List rows at the desktop's spacing (its track and queue rows are 45
        // and 53 pt): the macOS default packed them into about 24.
        .environment(\.defaultMinListRowHeight, 44 * zoom)
        // View > Zoom: every text style, cover and row below reads it (UIScale.swift).
        .environment(\.uiScale, zoom)
        .font(.system(size: 13 * zoom))
        #if DEBUG
        // Debug builds only: `-cascade.section songs` opens a section at
        // launch, to check it without clicking (UI scripting is not allowed).
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "cascade.section"), let s = MacSection(rawValue: raw) { section = s }
            // `-cascade.nowPlaying YES` opens Now Playing (paused on a restored queue: nothing plays).
            if UserDefaults.standard.bool(forKey: "cascade.nowPlaying") { state.nowPlayingOpen = true }
            DebugScrollProbe.runIfAsked()
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
        // The desktop's sidebar rows are 36 pt with 15 pt icons; .large is
        // the closest the system sidebar goes.
        .environment(\.sidebarRowSize, .large)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pinned under the list so it is always there, like the desktop's.
            // Downloads above Settings, in both modes: offline it is where
            // everything is, whichever mode is showing.
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 2) {
                    ForEach(MacSection.pinned.filter { $0 != .downloads || state.offline != nil }) { item in
                        Button { section = item; query = "" } label: {
                            // The list rows' size, not the zoomed window font: the system sidebar
                            // above ignores View > Zoom, and these were smaller at 1 and far larger at 1.75.
                            Label(item.title, systemImage: item.symbol)
                                .font(.system(size: 14))
                                .imageScale(.large)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 9).padding(.horizontal, 10)
                                .background(section == item ? Color.accentColor.opacity(0.22) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                }
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
            case .radio: state.showsRadio && !state.isOffline
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
        pending = (target, item)
    }
}

enum MacSection: String, Hashable, Identifiable, CaseIterable {
    case home, albums, artists, songs, playlists, genres, history, radio, downloads, movies, shows, settings

    var id: Self { self }

    static func sidebar(for mode: AppState.BrowseMode) -> [MacSection] {
        mode == .video ? [.home, .movies, .shows] : [.home, .albums, .artists, .songs, .playlists, .genres, .history, .radio]
    }

    /// Under the list, in both modes.
    static let pinned: [MacSection] = [.downloads, .settings]

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
        case .downloads: "Downloads"
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
        case .downloads: "arrow.down.circle"
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
        case .downloads: DownloadsView()
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
