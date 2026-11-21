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
    @AppStorage(MacNowPlayingUI.layoutKey) private var npLayout = MacNowPlayingUI.Layout.bar

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
            .background(Cx.bg)
            // The title bar on the page's bg, as the Penpot Mac title bar.
            .toolbarBackground(Cx.bg, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
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
                ToolbarItem(placement: .primaryAction) { AnnouncementsButton() }
                ToolbarItem(placement: .primaryAction) { ThemePanelButton() }
                // In the middle of the bar, as on the desktop. A field of its own: .searchable
                // with .toolbarPrincipal was sent to the overflow menu with Songs' sort and
                // filter buttons in the bar.
                ToolbarItem(placement: .principal) {
                    // Personality v1's field: surface-2, 8 pt corners, the shortcut at the end.
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Cx.text3)
                        TextField("Search your library", text: $query)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onExitCommand { query = ""; searchFocused = false }
                        if query.isEmpty {
                            Text("\u{2318}K").foregroundStyle(Cx.text3).accessibilityHidden(true)
                        } else {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Cx.text3)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .cx(.small)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Cx.surface2, in: RoundedRectangle(cornerRadius: 8))
                    // Grows with View > Zoom, so the zoomed placeholder is not cut off.
                    .frame(width: 440 * min(zoom, 1.5))
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
            // Player bar stays: Now Playing covers the window body only, under the title bar
            // and over the library, with the player bar left in place below it.
            .overlay { if npLayout == .bar { NowPlayingOverlay(bar: true) } }
            .animation(.easeInOut(duration: 0.25), value: MacNowPlayingUI.shared.sidePanelOpen)
            if let player = state.player {
                PlayerBar(player: player)
            }
        }
        // Over the library's bottom corner, just above the player bar.
        .overlay(alignment: .bottomTrailing) {
            // Not on Home, whose card offers the same queue back.
            if let offer = state.restoreOffer, !state.nowPlayingOpen, section != .home || isSearching {
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
            // Controls under the art: Now Playing takes the whole window, player bar included.
            if npLayout == .under { NowPlayingOverlay(bar: false) }
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
        .frame(minWidth: 800, minHeight: 560)
        // List rows at the desktop's spacing (its track and queue rows are 45
        // and 53 pt): the macOS default packed them into about 24.
        .environment(\.defaultMinListRowHeight, 44 * zoom)
        // View > Zoom: every text style, cover and row below reads it (UIScale.swift).
        .environment(\.uiScale, zoom)
        // font.body (Inter) for anything without a style of its own, unless the Theme
        // panel's UI font says otherwise (Font.cxBody).
        .font(.cxBody(13 * zoom))
        #if DEBUG
        // Debug builds only: `-cascade.section songs` opens a section at
        // launch, to check it without clicking (UI scripting is not allowed).
        .onAppear {
            if let raw = UserDefaults.standard.string(forKey: "cascade.section"), let s = MacSection(rawValue: raw) { section = s }
            // `-cascade.nowPlaying YES` opens Now Playing (paused on a restored queue: nothing plays).
            if UserDefaults.standard.bool(forKey: "cascade.nowPlaying") { state.nowPlayingOpen = true }
            DebugScrollProbe.runIfAsked()
        }
        // `-cascade.openItem <id>` pushes an album, artist or playlist page in the section;
        // `album`, `artist` or `playlist` picks the last played album, its artist, or the first playlist.
        .task {
            guard let want = UserDefaults.standard.string(forKey: "cascade.openItem"), let client = state.client else { return }
            let recent = want == "album" || want == "artist" ? try? await client.recentlyPlayedAlbums(maxAlbums: 1).first : nil
            let id: String? = switch want {
            case "album": recent?.id
            case "artist": (recent?.albumArtists?.first ?? recent?.artistItems?.first)?.id
            case "playlist": try? await client.playlists().first?.id
            default: want
            }
            guard let id, let item = try? await client.item(id: id) else { return }
            pending = (section, item)
        }
        #endif
    }

    /// Personality v1's sidebar: the Cascade logo as Home ("Your Cascade"), then Library,
    /// Listening and Video under their caps labels, Downloads and Settings at the foot.
    /// Both modes' sections show at once, as on Flutter's desktop: picking one switches
    /// the Music / Video mode it belongs to (search and deep links still read the mode).
    /// Rows of its own rather than a sidebar List, whose selection is the system's
    /// highlight, not the accent tint.
    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarBrand(active: section == .home && !isSearching) { go(.home) }
                    ForEach(MacSection.groups, id: \.title) { group in
                        let rows = group.sections.filter(isVisible)
                        if !rows.isEmpty {
                            Text(group.title).cx(.caps).foregroundStyle(Cx.text3)
                                .padding(.leading, 10).padding(.top, 16).padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(rows) { item in
                                SidebarRow(item: item, active: section == item && !isSearching) { go(item) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            // Pinned under the list so it is always there, like the desktop's.
            // Downloads above Settings, in both modes: offline it is where
            // everything is, whichever mode is showing.
            VStack(spacing: 2) {
                ForEach(MacSection.pinned.filter { $0 != .downloads || state.offline != nil }) { item in
                    SidebarRow(item: item, active: section == item && !isSearching) { go(item) }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
        .scrollContentBackground(.hidden)
        // Personality v1's sidebar: surface at 72% over the page's bg, under the title bar too.
        .background(Cx.surface.opacity(0.72).background(Cx.bg).ignoresSafeArea())
    }

    private func go(_ item: MacSection) {
        if let mode = BrowseModeLogic.sectionMode(item.rawValue), mode.rawValue != state.browseMode.rawValue {
            state.browseMode = AppState.BrowseMode(rawValue: mode.rawValue) ?? state.browseMode
        }
        section = item
        query = ""
    }

    /// Movies and TV Shows only once a library of that kind exists (or before the
    /// server has been asked), so a row never leads to a screen that cannot have
    /// anything on it. A server with only video hides the music side.
    private func isVisible(_ item: MacSection) -> Bool {
        switch item {
        case .movies: !libraries.isLoaded || !libraries.movieLibraries.isEmpty
        case .shows: !libraries.isLoaded || !libraries.showLibraries.isEmpty
        // Opted in and allowed Live TV; otherwise the row only leads to
        // a 403 or a prompt nobody asked for. Settings turns it on.
        case .radio: state.showsRadio && !state.isOffline
        default: true
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

    /// The sidebar's groups under Home, as Flutter's desktop and the Penpot Mac sidebar.
    static let groups: [(title: String, sections: [MacSection])] = [
        ("Library", [.albums, .artists, .songs, .playlists, .genres]),
        ("Listening", [.history, .radio]),
        ("Video", [.movies, .shows]),
    ]

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

    /// Outline symbols, the Penpot Mac sidebar's icon set.
    var symbol: String {
        switch self {
        case .home: "house"
        case .albums: "record.circle"
        case .artists: "person"
        case .songs: "music.note"
        case .playlists: "list.bullet"
        case .genres: "tag"
        case .history: "clock"
        case .radio: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.to.line"
        case .movies: "film"
        case .shows: "tv"
        case .settings: "slider.horizontal.3"
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

/// One Home for both modes on the Mac: it has Continue watching, as the Penpot Mac Home does.
private typealias HomeOrVideoHome = MacHomeView

/// The Cascade logo as the Home row, labeled Your Cascade (Flutter's _HomeBrand).
private struct SidebarBrand: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let image = PlatformImage(named: "512x512") { Image(nsImage: image).resizable() }
                }
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "house.fill").font(.system(size: 14)).foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .opacity(hovering ? 1 : 0)
                }
                Text("Your Cascade").font(.display(17, .semibold, italic: true)).foregroundStyle(Cx.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(active ? Cx.accentTint : hovering ? Cx.line : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Home")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One sidebar row: icon and name, the accent tint when it is the open section.
private struct SidebarRow: View {
    let item: MacSection
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .frame(width: 16)
                    .foregroundStyle(active ? Cx.accent : hovering ? Cx.text : Cx.text2)
                Text(item.title).cx(.row).foregroundStyle(Cx.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? Cx.accentTint : hovering ? Cx.line : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
