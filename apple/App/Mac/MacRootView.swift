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
        case .radio: ContentUnavailableView("Radio", systemImage: "dot.radiowaves.left.and.right")
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

/// What is playing, along the bottom of the window: art and title, transport,
/// a scrubber and the volume.
struct PlayerBar: View {
    let player: PlaybackService

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                ArtworkView(itemId: player.item?.albumId ?? player.item?.id, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.item?.name ?? "Not playing").lineLimit(1)
                    Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 240, alignment: .leading)

            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                        .accessibilityLabel("Shuffle")
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous")
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.title2)
                    }
                    .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next")
                    Button { player.cycleRepeat() } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    }
                    .foregroundStyle(player.repeatMode == .none ? .secondary : Color.accentColor)
                    .accessibilityLabel("Repeat")
                }
                .buttonStyle(.plain)
                Scrubber(player: player)
            }
            .frame(maxWidth: 520)

            HStack(spacing: 6) {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .onTapGesture { player.setMuted(!player.isMuted) }
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                    .frame(width: 110)
                    .accessibilityLabel("Volume")
            }
            .frame(width: 240, alignment: .trailing)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(player.item == nil)
    }
}

/// The position slider. Holds its own value while dragging so the half-second
/// position updates do not yank the knob back under the pointer.
struct Scrubber: View {
    let player: PlaybackService
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(clock(dragging ?? player.positionSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { dragging ?? player.positionSeconds }, set: { dragging = $0 }),
                   in: 0...max(player.durationSeconds, 1)) { editing in
                if !editing, let target = dragging {
                    Task {
                        await player.seek(to: target)
                        dragging = nil
                    }
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Position")
            Text(clock(player.durationSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
