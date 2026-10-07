import SwiftUI
import CascadeKit

/// The full-window Now Playing layer. Shown while AppState.nowPlayingOpen; while it is closed and
/// the side lyrics panel is open, it draws that instead, and while neither shows it draws nothing
/// at all (no timelines running, nothing to hit-test).
struct NowPlayingOverlay: View {
    @Environment(AppState.self) private var state
    private var ui: MacNowPlayingUI { .shared }
    private var prefs: LyricsPrefs { .shared }

    // Radio has no lyrics, so it never asks for them.
    private var wantsLyrics: Bool {
        ((state.nowPlayingOpen && ui.rightPanel == .lyrics) || ui.sidePanelOpen) && !(state.player?.isRadio ?? false)
    }

    var body: some View {
        ZStack {
            if let player = state.player {
                if state.nowPlayingOpen {
                    // trackActionHost: Media Info, Delete and multi-song Add to
                    // Playlist from the More menu present from here.
                    OverlayContent(player: player)
                        .trackActionHost()
                        .transition(.move(edge: .bottom))
                        .zIndex(2)
                } else if ui.sidePanelOpen {
                    SideLyricsPanel(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .translationHost(ui.translator)
        #if DEBUG
        .task { await NowPlayingDebug.run(state) }
        #endif
        // Lyrics are asked for only while something shows them. Everything that changes
        // which lyrics a song gets (the plugin turning up, server-only, a Spotify link, a
        // forced source, a reload) asks again.
        .task(id: [state.player?.item?.id ?? "", String(describing: state.cascadePluginApi),
                   "\(state.cascadePluginInfo.capabilities.sorted())", "\(state.serverOnlyLyrics)",
                   state.localSpotifyLinks[state.player?.item?.id ?? ""] ?? "", "\(state.lyricsRevision)",
                   prefs.forcedSource.rawValue, "\(wantsLyrics)", "\(ui.reloadTick)"]) {
            guard wantsLyrics else { return }
            await ui.lyrics.load(item: state.player?.item, state: state)
        }
        // A new sheet (or none) tells the translator, which works out its language.
        .onChange(of: ui.lyrics.lines?.first?.start) { syncTranslator() }
        .onChange(of: state.player?.item?.id) { syncTranslator() }
        .onChange(of: ui.lyrics.isLoading) { syncTranslator() }
        .onChange(of: prefs.translationEnabled) { ui.translator.enabledChanged() }
        .alert("Install \(LyricLanguages.displayName(ui.translator.promptingInstall ?? "")) in macOS?",
               isPresented: Binding(get: { ui.translator.promptingInstall != nil },
                                    set: { if !$0 { ui.translator.dismissInstallPrompt() } })) {
            Button("Open Language & Region") { ui.translator.openLanguageSettings() }
            Button("Cancel", role: .cancel) { ui.translator.dismissInstallPrompt() }
        } message: {
            Text("Translation runs on this Mac and downloads nothing through Cascade. The language just needs to be installed in macOS first: click Translation Languages in Language & Region and download it, then press Translate again.")
        }
        .sheet(isPresented: Binding(get: { ui.linkingSpotify }, set: { ui.linkingSpotify = $0 })) {
            if let track = state.player?.item { SpotifyLinkSheet(track: track).environment(state) }
        }
        .animation(.easeInOut(duration: 0.38), value: state.nowPlayingOpen)
        .animation(.easeInOut(duration: 0.25), value: ui.sidePanelOpen)
    }

    private func syncTranslator() {
        let model = ui.lyrics
        ui.translator.sheetChanged(lines: model.lines, id: model.lines == nil ? nil : state.player?.item?.id,
                                   player: state.player)
    }
}

// MARK: - The overlay

private struct OverlayContent: View {
    @Environment(\.showLibraryItem) private var showLibraryItem
    let player: PlaybackService
    @Environment(AppState.self) private var state
    private var ui: MacNowPlayingUI { .shared }
    private var theme: MacTheme { .shared }

    /// Overrides of the playing item's snapshot, which a server answer does not update. Reset on
    /// every track change.
    @State private var favoriteOverride: Bool?
    @State private var playedOverride: Bool?
    @State private var addingToPlaylist = false
    /// The controls fold away after 3 s without a sign of life, while something is playing; the
    /// progress row stays, so a glance still says where you are.
    @State private var idle = false
    @State private var wake = 0
    @State private var artHovering = false

    private var artId: String? { player.item?.albumId ?? player.item?.id }
    private var light: Bool { theme.isLight }
    private var artTheme: Bool { theme.settings.albumArt }
    private var ink: Color { light ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white }
    private var showingLyrics: Bool { ui.rightPanel == .lyrics }
    private var isFavorite: Bool { favoriteOverride ?? player.item?.userData?.isFavorite ?? false }
    /// A white scrim over each part in light mode with album art, so text reads over the blobs.
    private var scrim: Color { light && artTheme ? .white.opacity(theme.tuning.bgDim) : .clear }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    leftColumn
                    rightPanel
                }
            }
            // Esc closes it, as the chevron does. A hidden button, so it works without focus.
            Button("", action: close).keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0)
        }
        .foregroundStyle(ink)
        .environment(\.lyricInk, ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window's toolbar (Music/Video, search, theme) is the library's, not Now Playing's:
        // hidden while this is open, as the video player does. The traffic lights stay.
        .background(ToolbarHider())
        .onContinuousHover { _ in poke() }
        .simultaneousGesture(TapGesture().onEnded { poke() })
        .task(id: "\(wake)|\(player.isPaused)") {
            idle = false
            // Paused is not idle: hiding the controls of something that is going nowhere reads as
            // broken, and pause is when you are most likely to reach for them.
            guard !player.isPaused else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { idle = true }
        }
        .task(id: player.item?.id) {
            favoriteOverride = nil
            playedOverride = nil
        }
        .sheet(isPresented: $addingToPlaylist) {
            if let track = player.item { AddToPlaylistSheet(track: track).environment(state) }
        }
    }

    private func poke() {
        if idle { withAnimation(.easeInOut(duration: 0.2)) { idle = false } }
        wake += 1
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.38)) { state.nowPlayingOpen = false }
    }

    // MARK: Background

    @ViewBuilder private var background: some View {
        if artTheme {
            NowPlayingBackground(itemId: artId, behindLyrics: showingLyrics, light: light, multiply: theme.tuning.bgBlend)
        } else {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Button(action: close) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                    Text("Now Playing").font(.caption.weight(.semibold))
                }
                .foregroundStyle(ink.opacity(0.6))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Now Playing (Esc)")
            .accessibilityLabel("Close Now Playing")
            HStack {
                Spacer()
                ThemePanelButton().buttonStyle(.plain).foregroundStyle(ink.opacity(0.6))
            }
            .padding(.trailing, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(scrim)
    }

    // MARK: Left column

    private var leftColumn: some View {
        GeometryReader { geo in
            let side = max(180, min(geo.size.width - 80, geo.size.height * (idle ? 0.58 : 0.5)))
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                art(side: side)
                VStack(spacing: 3) {
                    Text(player.item?.name ?? "Nothing playing").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(player.item?.albumArtist ?? player.item?.artists?.first ?? "")
                        .foregroundStyle(ink.opacity(0.7)).lineLimit(1)
                }
                if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
                controls.frame(maxWidth: min(side + 80, 460))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity)
        .background(scrim)
        .animation(.easeInOut(duration: 0.35), value: idle)
    }

    /// The cover, with Favorite, Add to Playlist and View Album over it while the pointer is on it.
    private func art(side: CGFloat) -> some View {
        ArtworkView(itemId: artId, size: side, fillsFrame: true)
            .frame(width: side, height: side)
            .brightness(artHovering ? -0.25 : 0)
            .saturation(artHovering ? 0.7 : 1)
            .overlay {
                HStack(spacing: 14) {
                    artButton(isFavorite ? "heart.fill" : "heart", label: isFavorite ? "Unfavorite" : "Favorite",
                              tint: isFavorite ? Color(red: 1, green: 0.42, blue: 0.54) : .white, action: toggleFavorite)
                    artButton("text.badge.plus", label: "Add to playlist") { addingToPlaylist = true }
                    artButton("square.stack", label: "View album", action: viewAlbum)
                }
                .opacity(artHovering ? 1 : 0)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .onHover { artHovering = $0 }
            .animation(.easeOut(duration: 0.2), value: artHovering)
            // Apple's artwork breathes with playback: full size while playing, eased back a
            // little when paused.
            .scaleEffect(player.isPaused ? 0.94 : 1)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: player.isPaused)
    }

    private func artButton(_ symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(.ultraThinMaterial))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func toggleFavorite() {
        guard let id = player.item?.id, let client = state.client else { return }
        let target = !isFavorite
        // Flips only once the server has accepted it (CODEMAP rule 1).
        Task {
            do {
                try await client.setFavorite(target, itemId: id)
                if player.item?.id == id { favoriteOverride = target }
            } catch {}
        }
    }

    private func viewAlbum() {
        guard let item = player.item, let albumId = item.albumId else { return }
        var album = JfItem(id: albumId, name: item.album, type: "MusicAlbum")
        album.albumArtist = item.albumArtist
        close()
        // Through the shell's deep link, which switches to Music and Albums first.
        showLibraryItem?(album)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            progress
            if !idle {
                VStack(spacing: 14) {
                    transport
                    volume
                    secondary
                }
                .transition(.opacity)
            }
        }
    }

    @State private var scrubbing: Double?

    @ViewBuilder private var progress: some View {
        if player.isRadio {
            // A live stream has no length to scrub.
            Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(ink.opacity(0.8))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().stroke(ink.opacity(0.5)))
        } else {
            scrubber
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(clock(scrubbing.map { $0 * player.durationSeconds } ?? player.positionSeconds))
                .font(.caption2.monospacedDigit()).foregroundStyle(ink.opacity(0.6))
            MacSlider(value: scrubbing ?? (player.durationSeconds > 0 ? player.positionSeconds / player.durationSeconds : 0),
                      step: 5 / max(player.durationSeconds, 1), bigStep: 30 / max(player.durationSeconds, 1),
                      fill: ink, label: "Seek",
                      valueText: { "\(clock($0 * player.durationSeconds)) of \(clock(player.durationSeconds))" },
                      onChange: { scrubbing = $0 },
                      onCommit: { ratio in
                          Task {
                              await player.seek(to: ratio * player.durationSeconds)
                              scrubbing = nil
                          }
                      })
            Text(clock(player.durationSeconds)).font(.caption2.monospacedDigit()).foregroundStyle(ink.opacity(0.6))
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle").font(.system(size: 16)) }
                .foregroundStyle(player.shuffle ? MacTheme.shared.accent : ink.opacity(0.7))
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffle ? "On" : "Off")
            Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill").font(.system(size: 22)) }
                .accessibilityLabel("Previous")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(HexColor.prefersDarkInk(over: theme.accentHex) ? Color.black : Color.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(MacTheme.shared.accent))
                    .contentShape(Circle())
            }
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            Button { Task { await player.next() } } label: { Image(systemName: "forward.fill").font(.system(size: 22)) }
                .accessibilityLabel("Next")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 16))
            }
            .foregroundStyle(player.repeatMode == .none ? ink.opacity(0.7) : MacTheme.shared.accent)
            .accessibilityLabel("Repeat")
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Button { player.setMuted(!player.isMuted) } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            MacSlider(value: Double(player.isMuted ? 0 : player.volume), fill: ink.opacity(0.6), label: "Volume") {
                if player.isMuted { player.setMuted(false) }
                player.setVolume(Float($0))
            }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(ink.opacity(0.6))
    }

    private var secondary: some View {
        HStack {
            moreMenu
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { ui.rightPanel = showingLyrics ? .queue : .lyrics }
            } label: {
                Image(systemName: showingLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 17))
                    .frame(width: 36, height: 30)
                    .background(Circle().fill(showingLyrics ? ink.opacity(0.18) : .clear))
            }
            .buttonStyle(.plain)
            .help("Lyrics")
            .accessibilityLabel("Lyrics")
            .accessibilityValue(showingLyrics ? "Showing" : "")
        }
    }

    /// The same actions as a track row's menu, then the rest the desktop's More menu has.
    private var moreMenu: some View {
        Menu {
            if let track = player.item {
                TrackMenuItems(track: track, favorite: $favoriteOverride, played: $playedOverride,
                               addingToPlaylist: $addingToPlaylist, nowPlaying: true)
            }
            Section {
                SleepTimerMenu(player: player)
                LyricsTimingMenu()
                if state.cascadePluginInfo.spotifyLink, player.item != nil {
                    Button("Link Spotify Track\u{2026}", systemImage: "link") { ui.linkingSpotify = true }
                }
            }
            Section {
                Button("Stop Playback", systemImage: "stop.fill") {
                    Task {
                        await player.stop()
                        close()
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17))
                .frame(width: 36, height: 30)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    // MARK: Right panel

    /// The queue always, with lyrics sliding over it.
    private var rightPanel: some View {
        ZStack {
            QueuePanel(player: player)
                .opacity(showingLyrics ? 0 : 1)
                .offset(x: showingLyrics ? -40 : 0)
                .allowsHitTesting(!showingLyrics)
            VStack(spacing: 8) {
                LyricsPanelHeader()
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                MacLyricsBody(player: player)
                    .padding(.horizontal, 12)
            }
            .opacity(showingLyrics ? 1 : 0)
            .offset(x: showingLyrics ? 0 : 40)
            .allowsHitTesting(showingLyrics)
        }
        .frame(maxWidth: .infinity)
        .background(scrim)
        .clipped()
    }
}

// MARK: - More menu pieces

/// The desktop's sleep timer choices, as a submenu of More.
struct SleepTimerMenu: View {
    let player: PlaybackService

    var body: some View {
        Menu {
            switch player.sleepTimer {
            case .at(let date): Text("Pauses at \(date.formatted(date: .omitted, time: .shortened))")
            case .endOfTrack: Text("Pauses after this track")
            case .off: EmptyView()
            }
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
            }
            Button("End of Current Track") { player.setSleepTimerAtEndOfTrack() }
            if player.sleepTimer != .off {
                Button("Turn Off", role: .destructive) { player.cancelSleepTimer() }
            }
        } label: {
            Label(player.sleepTimer == .off ? "Sleep Timer" : "Sleep Timer (On)",
                  systemImage: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
    }
}

/// Nudges the lyrics against the audio, for an output (Bluetooth especially) where they run early
/// or late. The one lyric lead for every window: it is StyleTuning's lyricsDelay, which the
/// miniplayer reads too (the desktop's two windows once differed, 0.35 s and 0.225 s).
struct LyricsTimingMenu: View {
    var body: some View {
        // Counted from the default, which already leads a little: "in time" means as shipped,
        // and Reset goes back there, not to zero.
        let delay = StyleTuning.shared.values.lyricsDelay
        let standard = StyleTuning.Values().lyricsDelay
        let offset = delay - standard
        Menu {
            Text(abs(offset) < 0.001 ? "In time with the audio"
                 : "\(abs(offset), format: .number.precision(.fractionLength(2))) s \(offset > 0 ? "later" : "earlier")")
            Button("Later by 0.1 s", systemImage: "plus") { nudge(delay, 0.1) }
            Button("Earlier by 0.1 s", systemImage: "minus") { nudge(delay, -0.1) }
            if abs(offset) >= 0.001 {
                Button("Reset", systemImage: "arrow.counterclockwise") { StyleTuning.shared.values.lyricsDelay = standard }
            }
        } label: {
            Label("Lyrics Timing", systemImage: "timer")
        }
    }

    private func nudge(_ delay: Double, _ by: Double) {
        StyleTuning.shared.values.lyricsDelay = ((delay + by) * 20).rounded() / 20
    }
}

/// Hides the window's toolbar while it is on screen and puts it back after,
/// through the NSWindow, since SwiftUI's own toolbar visibility took the
/// traffic lights with it.
private struct ToolbarHider: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var wasVisible: Bool?
        var titleWas: NSWindow.TitleVisibility?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, let toolbar = window.toolbar else { return }
            context.coordinator.window = window
            context.coordinator.wasVisible = toolbar.isVisible
            context.coordinator.titleWas = window.titleVisibility
            toolbar.isVisible = false
            window.titleVisibility = .hidden
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let wasVisible = coordinator.wasVisible { coordinator.window?.toolbar?.isVisible = wasVisible }
        if let titleWas = coordinator.titleWas { coordinator.window?.titleVisibility = titleWas }
    }
}
