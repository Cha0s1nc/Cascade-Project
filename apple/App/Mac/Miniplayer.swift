import SwiftUI
import AppKit
import CascadeKit

// The miniplayer, ported from miniplayer.html and main.js (the miniplayer window code). Unlike
// the desktop's remote-control window it is a second view onto the one PlaybackService, so
// every control calls the player directly.

private enum MiniSize {
    static let width: CGFloat = 300
    static let minHeight: CGFloat = 100
    static let maxHeight: CGFloat = 900
    static let defaultHeight: CGFloat = 120
    /// Under this the layout is the compact bar; from it up, a cover with the controls over it.
    static let tallFrom: CGFloat = 180
    static let idleSeconds = 2.6

    /// A stale height from a build with another range must not hand the window a size outside this one.
    static var savedHeight: CGFloat {
        let h = UserDefaults.standard.object(forKey: "cascade.miniplayerHeight") as? Double ?? 0
        return h >= minHeight && h <= maxHeight ? h : defaultHeight
    }
}

struct MiniplayerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let player = state.player { MiniplayerBody(player: player) }
            else { Text("Nothing playing").foregroundStyle(.secondary) }
        }
        .frame(minWidth: MiniSize.width, maxWidth: MiniSize.width, minHeight: MiniSize.minHeight, maxHeight: MiniSize.maxHeight)
        .macThemed()
    }
}

private struct MiniplayerBody: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow
    private var ui: MacNowPlayingUI { .shared }

    private enum Tab { case lyrics, queue }
    @State private var tab = Tab.lyrics
    @State private var hovering = false
    @State private var idle = false
    @State private var activity = 0
    @State private var lastBump = Date.distantPast
    @State private var volumeHud: Float?
    @State private var hudTask: Task<Void, Never>?
    @State private var favoriteOverride: Bool?
    @FocusState private var focused: Bool

    private var item: JfItem? { player.item }
    private var isFavorite: Bool { favoriteOverride ?? item?.userData?.isFavorite ?? false }
    private var artId: String? { item?.albumId ?? item?.id }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if geo.size.height >= MiniSize.tallFrom { tall(height: geo.size.height) }
                else { compact }
                volumeReadout
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background { VisualEffectBackground(material: .hudWindow).ignoresSafeArea() }
        .background(MiniplayerWindowSetup(hovering: hovering))
        .environment(\.colorScheme, .dark)
        .environment(\.lyricInk, .white)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) { player.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { Task { await player.previous() }; return .handled }
        .onKeyPress(.rightArrow) { Task { await player.next() }; return .handled }
        .onKeyPress(.upArrow) { nudgeVolume(0.05); return .handled }
        .onKeyPress(.downArrow) { nudgeVolume(-0.05); return .handled }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                hovering = true
                // Throttled: every pointer move would otherwise restart the idle timer and redraw.
                if Date().timeIntervalSince(lastBump) > 0.15 { lastBump = Date(); activity += 1 }
            case .ended: hovering = false
            }
        }
        .task(id: activity) {
            idle = false
            try? await Task.sleep(for: .seconds(MiniSize.idleSeconds))
            if !Task.isCancelled { idle = true }
        }
        .onChange(of: item?.id) { favoriteOverride = nil }
        // Lyrics are asked for only while shown, as in the overlay; the model is the same one.
        .task(id: [item?.id ?? "", String(describing: state.cascadePluginApi),
                   "\(state.cascadePluginInfo.capabilities.sorted())", "\(state.serverOnlyLyrics)",
                   state.localSpotifyLinks[item?.id ?? ""] ?? "", "\(state.lyricsRevision)",
                   LyricsPrefs.shared.forcedSource.rawValue, "\(tab)", "\(ui.reloadTick)"]) {
            guard tab == .lyrics else { return }
            await ui.lyrics.load(item: item, state: state)
        }
    }

    // MARK: Layouts

    /// A bar: art, title, transport and the scrubber. The transport fades when idle and the
    /// title takes the room.
    private var compact: some View {
        HStack(spacing: 12) {
            cover.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { dismissWindow(id: "miniplayer") }
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 4) {
                titleBlock(size: 13).onTapGesture { dismissWindow(id: "miniplayer") }
                transport(size: 14).opacity(idle ? 0 : 1)
                MiniProgress(player: player).opacity(idle ? 0.5 : 1)
            }
            .padding(.trailing, 14)
        }
        .padding(.top, 14)
        .background(WheelCatcher(onScroll: wheelVolume))
        .animation(.easeOut(duration: 0.25), value: idle)
    }

    private func tall(height: CGFloat) -> some View {
        let coverHeight = min(MiniSize.width, height)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                cover
                    .frame(width: MiniSize.width, height: MiniSize.width)
                    .frame(height: coverHeight)
                    .clipped()
                    .onTapGesture { dismissWindow(id: "miniplayer") }
                    // Over the cover the wheel sets the volume; over the panel it scrolls.
                    .background(WheelCatcher(onScroll: wheelVolume))
                VStack(spacing: 10) {
                    HStack(alignment: .bottom) {
                        titleBlock(size: 16)
                        Spacer(minLength: 8)
                        likeButton
                    }
                    MiniProgress(player: player)
                    transport(size: 18)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.5), location: 0.5),
                                           .init(color: .clear, location: 1)], startPoint: .bottom, endPoint: .top)
                        .padding(.top, -90)
                )
                .opacity(idle ? 0 : 1)
                .allowsHitTesting(!idle)
            }
            .frame(height: coverHeight)
            if height >= MiniSize.width + 60 { panel }
        }
        .animation(.easeOut(duration: 0.25), value: idle)
    }

    // MARK: Pieces

    private var cover: some View {
        ArtworkView(itemId: artId, size: 300, fillsFrame: true)
    }

    private func titleBlock(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item?.name ?? "Not playing").font(.system(size: size, weight: .semibold)).lineLimit(1)
            Text(item?.albumArtist ?? item?.artists?.first ?? "")
                .font(.system(size: size - 3)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var likeButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? Color(red: 1, green: 0.42, blue: 0.54) : .white)
                .font(.system(size: 16))
        }
        .buttonStyle(.hover)
        .help(isFavorite ? "Unfavorite" : "Favorite")
        .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
    }

    private func transport(size: CGFloat) -> some View {
        HStack(spacing: size + 4) {
            Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill").font(.system(size: size + 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
        }
        .font(.system(size: size))
        .buttonStyle(.hover)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                tabButton("Lyrics", .lyrics)
                tabButton("Up Next", .queue)
                Spacer()
                if tab == .queue { queueControls }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if tab == .lyrics {
                MacLyricsBody(player: player)
                    .environment(\.lyricScale, 0.5)
                    .padding(.horizontal, 12)
            } else {
                upNext
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        Button { tab = value } label: {
            Text(title).font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(tab == value ? Color.white.opacity(0.2) : .clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tab == value ? .white : .secondary)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private var queueControls: some View {
        HStack(spacing: 12) {
            Button { player.autoMix.toggle() } label: { Image(systemName: "infinity") }
                .foregroundStyle(player.autoMix ? MacTheme.shared.accent : .secondary)
                .help("Autoplay: keep playing similar tracks when the queue ends")
                .accessibilityLabel("Autoplay")
            Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .foregroundStyle(player.shuffle ? MacTheme.shared.accent : .secondary)
                .help("Shuffle")
                .accessibilityLabel("Shuffle")
            Button { player.cycleRepeat() } label: { Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat") }
                .foregroundStyle(player.repeatMode == .none ? .secondary : MacTheme.shared.accent)
                .help("Repeat")
                .accessibilityLabel("Repeat")
        }
        .buttonStyle(.hover)
    }

    private var upNext: some View {
        let start = max(player.queue.index + 1, 0)
        let items = Array(player.queue.items.enumerated()).dropFirst(start).prefix(50)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items), id: \.offset) { offset, track in
                    Button { Task { await player.jump(to: offset) } } label: {
                        HStack(spacing: 8) {
                            ArtworkView(itemId: track.albumId ?? track.id, size: 32).frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(track.name ?? "").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(track.albumArtist ?? track.artists?.first ?? "")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if items.isEmpty {
                    Text("Nothing up next").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                }
            }
        }
    }

    /// The readout the wheel and the up/down keys raise, gone 0.9 s after the last change.
    private var volumeReadout: some View {
        let pct = Int(((volumeHud ?? player.volume) * 100).rounded())
        return HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
            ProgressView(value: Double(pct) / 100).frame(width: 80).tint(.white)
            Text("\(pct)%").font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
        .opacity(volumeHud == nil ? 0 : 1)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: volumeHud == nil)
    }

    // MARK: Actions

    /// A wheel notch is 5 percent and a trackpad swipe is smooth; one event moves it 10 at most,
    /// as the desktop clamps it.
    private func wheelVolume(_ delta: CGFloat, _ precise: Bool) {
        nudgeVolume(Float(min(0.1, max(-0.1, delta * (precise ? 0.003 : 0.05)))))
    }

    private func nudgeVolume(_ delta: Float) {
        guard delta != 0 else { return }
        let next = min(1, max(0, (volumeHud ?? player.volume) + delta))
        // A wish to hear it, as on the player bar.
        if player.isMuted { player.setMuted(false) }
        player.setVolume(next)
        // Held locally while the wheel moves so a lagging state tick cannot yank the readout back.
        volumeHud = next
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { volumeHud = nil }
        }
    }

    private func toggleFavorite() {
        guard let id = item?.id, let client = state.client else { return }
        let target = !isFavorite
        // Flips only once the server has accepted it.
        Task {
            do {
                try await client.setFavorite(target, itemId: id)
                if player.item?.id == id { favoriteOverride = target }
            } catch {}
        }
    }
}

/// The thin position bar. A drag shows its target locally and seeks once on release, so a drag
/// across the bar is one seek and not dozens.
private struct MiniProgress: View {
    let player: PlaybackService
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.durationSeconds, 1)
        let shown = dragging ?? player.positionSeconds
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: geo.size.width * min(1, max(0, shown / duration)))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = fraction($0.location.x, geo.size.width) * duration }
                    .onEnded { value in
                        let target = fraction(value.location.x, geo.size.width) * duration
                        Task { await player.seek(to: target); dragging = nil }
                    })
            }
            .frame(height: 14)
            HStack {
                Text(clock(shown)); Spacer(); Text(clock(player.durationSeconds))
            }
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(clock(shown)) of \(clock(player.durationSeconds))")
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double { width > 0 ? Double(min(1, max(0, x / width))) : 0 }
}

// MARK: - The window

/// Turns the scene's window into the miniplayer: floating, out of the window cycle, no title bar
/// chrome (the traffic lights fade in only while the pointer is over it), the height from last
/// time and saved when it changes. The desktop's NSPanel behavior, on the window SwiftUI makes
/// (a real NSPanel would need its own scene host).
private struct MiniplayerWindowSetup: NSViewRepresentable {
    let hovering: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = SetupView()
        v.onWindow = { context.coordinator.attach($0) }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.setLights(visible: hovering) }

    final class SetupView: NSView {
        var onWindow: (NSWindow) -> Void = { _ in }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private(set) weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var saveTask: Task<Void, Never>?
        private var retry: Task<Void, Never>?

        func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.level = .floating
            window.collectionBehavior.insert([.ignoresCycle, .fullScreenAuxiliary])
            window.isExcludedFromWindowsMenu = true
            window.hidesOnDeactivate = false
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: .vibrantDark)
            window.contentMinSize = NSSize(width: MiniSize.width, height: MiniSize.minHeight)
            window.contentMaxSize = NSSize(width: MiniSize.width, height: MiniSize.maxHeight)
            window.setContentSize(NSSize(width: MiniSize.width, height: MiniSize.savedHeight))
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            setLights(visible: false)

            // The miniplayer stands in for the main window (miniaturized, never hidden: there is
            // no other way back to it).
            MainWindows.minimize(except: window)

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveHeightSoon() }
            })
            // However it closes (the light, Cmd-W, a click on the cover), the main window comes back.
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.saveTask?.cancel()
                    self?.observers.forEach(NotificationCenter.default.removeObserver)
                    self?.observers = []
                    MainWindows.restore()
                }
            })
        }

        func setLights(visible: Bool) {
            guard let window else { return }
            // Pointing at a native light can read as leaving the page; hiding it then would pull
            // the close button out from under the pointer (main.js hit this). The pointer decides.
            retry?.cancel()
            if !visible, window.frame.contains(NSEvent.mouseLocation) {
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    if !Task.isCancelled { self?.setLights(visible: false) }
                }
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
                }
            }
        }

        /// Debounced, so a live drag-resize does not write on every frame.
        private func saveHeightSoon() {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let h = self?.window?.contentView?.bounds.height else { return }
                UserDefaults.standard.set(Double(h.rounded()), forKey: "cascade.miniplayerHeight")
            }
        }

    }
}
