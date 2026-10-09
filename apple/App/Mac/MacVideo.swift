import SwiftUI
import AppKit
import AVKit
import CascadeKit

/// Plays AppState.videoSession over the whole window while it is set, or in
/// a corner of it while the video is minimized.
struct MacVideoHost: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let session = state.videoSession {
            @Bindable var state = state
            // Keyed by the session, so a second video starts with fresh chrome.
            MacVideoScreen(session: session, minimized: $state.videoMinimized) { state.closeVideo() }
                .id(ObjectIdentifier(session))
        }
    }
}

/// The player: full window with our controls over it (idle-hidden together
/// with the window's traffic lights and the cursor), the key handling and the
/// keys panel; or, minimized, a small picture in the corner that keeps playing
/// while the library is used. One view either way, so the picture (and a
/// Picture in Picture window on it) survives the switch.
struct MacVideoScreen: View {
    let session: VideoSession
    @Binding var minimized: Bool
    @State private var controller: MacVideoController

    init(session: VideoSession, minimized: Binding<Bool>, close: @escaping () -> Void) {
        self.session = session
        _minimized = minimized
        _controller = State(initialValue: MacVideoController(session: session, close: close,
                                                             setMinimized: { minimized.wrappedValue = $0 }))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            picture
                .frame(width: minimized ? 320 : nil, height: minimized ? 180 : nil)
                .frame(maxWidth: minimized ? nil : .infinity, maxHeight: minimized ? nil : .infinity)
                .clipShape(.rect(cornerRadius: minimized ? 10 : 0))
                .shadow(color: .black.opacity(minimized ? 0.4 : 0), radius: 14, y: 4)
                // Above the player bar, where the restore card sits.
                .padding(.trailing, minimized ? 16 : 0)
                .padding(.bottom, minimized ? 76 : 0)
        }
        .ignoresSafeArea(.all, edges: minimized ? [] : .all)
        .animation(.easeInOut(duration: 0.3), value: minimized)
        .background(WindowReader { controller.attach(to: $0) })
        .onContinuousHover { if case .active = $0, !minimized { controller.poke() } }
        .onChange(of: minimized, initial: true) { _, now in controller.minimizedChanged(now) }
        .onDisappear { controller.detach() }
        .onChange(of: session.finished) { _, done in if done { controller.requestClose() } }
    }

    private var picture: some View {
        ZStack {
            Color.black
            VideoPlayerView(session: session) { controller.pip.attach($0) }
            if minimized {
                MiniVideoControls(controller: controller)
            } else {
                // Above the picture, below the controls: a click pauses, a double
                // click is fullscreen. The tap that waits for a second click
                // delays the pause by the double-click interval, which is how
                // YouTube behaves too.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { controller.toggleFullscreen() }
                    .onTapGesture { session.togglePlayPause(); controller.poke() }
                MacVideoOverlay(controller: controller)
            }
        }
    }
}

/// The minimized picture's buttons, on hover. A click anywhere else on it
/// brings the video back.
private struct MiniVideoControls: View {
    let controller: MacVideoController
    @State private var hovering = false
    private var session: VideoSession { controller.session }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { controller.restore() }
            if controller.pipActive {
                Label("Playing in Picture in Picture", systemImage: "pip")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
            }
            if hovering {
                Color.black.opacity(0.35).allowsHitTesting(false)
                HStack(spacing: 20) {
                    Button { controller.restore() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Back to the video").accessibilityLabel("Back to the video")
                    Button { session.togglePlayPause() } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                    if controller.pip.isSupported {
                        Button { controller.pip.toggle() } label: { Image(systemName: controller.pipActive ? "pip.exit" : "pip.enter") }
                            .help("Picture in Picture").accessibilityLabel("Picture in Picture")
                    }
                    Button { controller.requestClose() } label: { Image(systemName: "xmark") }
                        .help("Stop the video").accessibilityLabel("Stop the video")
                }
                .font(.title3)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Hands the hosting window to the controller, once the view is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { [found] in found?(window) } }
        }
    }
}

/// Everything about the player that is the window's business rather than a
/// view's: the key monitor, the idle timer, the traffic lights, the toolbar
/// and fullscreen. Restores all of it in `detach`, which every way of ending
/// a video reaches (the close button, Esc, the last episode ending, sign-out).
@MainActor
@Observable
final class MacVideoController {
    let session: VideoSession
    private let close: () -> Void
    private let setMinimized: (Bool) -> Void
    let pip = VideoPiP()
    /// Shrunk to the corner (or out in Picture in Picture): the window's
    /// chrome and keys are the library's again.
    private(set) var minimized = false
    private(set) var pipActive = false

    /// The controls, title and traffic lights are showing.
    private(set) var controlsVisible = true {
        didSet { applyTrafficLights() }
    }
    /// A second of feedback in the middle of the picture.
    private(set) var osd: String?
    var showsKeys = false

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var osdTask: Task<Void, Never>?
    @ObservationIgnored private var toolbarWasVisible: Bool?
    @ObservationIgnored private var titleWas: NSWindow.TitleVisibility?
    @ObservationIgnored private var titleObservation: NSKeyValueObservation?
    @ObservationIgnored private var enteredFullscreen = false

    /// Seconds without a mouse move or key before the controls go.
    private static let idleSeconds = 2.5

    init(session: VideoSession, close: @escaping () -> Void, setMinimized: @escaping (Bool) -> Void) {
        self.session = session
        self.close = close
        self.setMinimized = setMinimized
        pip.onStart = { [weak self] in
            self?.pipActive = true
            // Out of the window: give the window back to the library.
            self?.minimize()
        }
        pip.onStop = { [weak self] in self?.pipActive = false }
        pip.onRestore = { [weak self] in self?.restore() }
    }

    // MARK: - Window

    func attach(to window: NSWindow) {
        guard self.window == nil else { return }
        self.window = window
        // The main window's toolbar (Music/Video switch, search) is drawn
        // above the content, so it would sit over the picture, and the
        // section's title ("Home") would show in the title bar.
        toolbarWasVisible = window.toolbar?.isVisible
        titleWas = window.titleVisibility
        // SwiftUI writes the section's title back as the library updates.
        titleObservation = window.observe(\.titleVisibility) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard self?.minimized == false, window.titleVisibility != .hidden else { return }
                DispatchQueue.main.async { window.titleVisibility = .hidden }
            }
        }
        applyChrome()
        // A search field left focused would take the video's keys.
        if !minimized { window.makeFirstResponder(nil) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread; NSEvent just is not Sendable.
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { self?.handle(e) == true }
            return consumed ? nil : event
        }
        poke()
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idleTask?.cancel()
        osdTask?.cancel()
        titleObservation = nil
        pip.stop()
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
        if let toolbarWasVisible { window.toolbar?.isVisible = toolbarWasVisible }
        if let titleWas { window.titleVisibility = titleWas }
        if enteredFullscreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        self.window = nil
    }

    private var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// Hidden while the controls are idle, as the desktop's cursor and chrome
    /// are. Fullscreen has its own, auto-hiding, so leave those alone.
    private func applyTrafficLights() {
        guard let window else { return }
        let hidden = !minimized && !controlsVisible && !isFullscreen
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

    func requestClose() { close() }

    /// The chevron and Esc: to the corner, still playing.
    func minimize() { setMinimized(true) }
    func restore() {
        if pipActive { pip.stop() }
        setMinimized(false)
    }

    /// Follows AppState.videoMinimized, however it changed.
    func minimizedChanged(_ now: Bool) {
        minimized = now
        if now {
            idleTask?.cancel()
            showsKeys = false
            controlsVisible = true
            if enteredFullscreen, isFullscreen { enteredFullscreen = false; window?.toggleFullScreen(nil) }
        } else {
            window?.makeFirstResponder(nil)
            poke()
        }
        applyChrome()
    }

    /// The library's toolbar and title while minimized; neither over the picture.
    private func applyChrome() {
        guard let window else { return }
        window.toolbar?.isVisible = minimized ? (toolbarWasVisible ?? true) : false
        window.titleVisibility = minimized ? (titleWas ?? .visible) : .hidden
        applyTrafficLights()
    }

    func toggleFullscreen() {
        guard let window else { return }
        enteredFullscreen = !isFullscreen
        window.toggleFullScreen(nil)
        poke()
    }

    // MARK: - Idle

    /// Mouse or key activity: show the controls and start the idle clock.
    func poke() {
        controlsVisible = true
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled, let self else { return }
            // Paused is a time to read the controls; playing is not.
            if self.session.isPlaying, !self.session.isScrubbing, !self.showsKeys { self.controlsVisible = false }
            // Hides until the mouse next moves, so no timer to undo it.
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func say(_ text: String) {
        osd = text
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.osd = nil
        }
    }

    // MARK: - Keys

    private enum Key {
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        static let escape: UInt16 = 53, home: UInt16 = 115, end: UInt16 = 119
    }

    /// True when the key was the player's. Anything with Command or Control
    /// belongs to the app and the system (Command-Q, Command-K), and Option
    /// only to the chapter keys; typing in a text field is left alone.
    private func handle(_ event: NSEvent) -> Bool {
        guard !minimized, let window, event.window === window else { return false }
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return false }
        poke()

        if mods.contains(.option) {
            guard event.keyCode == Key.left || event.keyCode == Key.right else { return false }
            if let chapter = session.jumpChapter(forward: event.keyCode == Key.right) { say(chapter.name) }
            return true
        }

        switch event.keyCode {
        case Key.escape:
            if showsKeys { showsKeys = false }
            else if isFullscreen { enteredFullscreen = false; window.toggleFullScreen(nil) }
            else { minimize() }
            return true
        case Key.left: session.skip(by: -VideoControls.arrowSeconds); return true
        case Key.right: session.skip(by: VideoControls.arrowSeconds); return true
        case Key.up: nudgeVolume(VideoControls.volumeStep); return true
        case Key.down: nudgeVolume(-VideoControls.volumeStep); return true
        case Key.home: session.seek(to: 0); return true
        case Key.end: session.seek(to: session.duration); return true
        default: break
        }

        // The character as typed, so Shift+, is "<" and Shift+/ is "?".
        guard let typed = event.characters, typed.count == 1, let ch = typed.first else { return false }
        switch ch {
        case " ", "k": session.togglePlayPause()
        case "j": session.skip(by: -VideoControls.skipSeconds)
        case "l": session.skip(by: VideoControls.skipSeconds)
        case "m":
            session.toggleMute()
            say(session.isMuted ? "Muted" : "Unmuted")
        case "f": toggleFullscreen()
        case "c": say(session.toggleSubtitles() ?? "No subtitles")
        case "0"..."9":
            if let target = VideoControls.tenthTarget(Int(String(ch))!, duration: session.duration) { session.seek(to: target) }
        case ",": session.step(forward: false)
        case ".": session.step(forward: true)
        case "<", ">":
            let rate = VideoControls.nextRate(from: session.rate, faster: ch == ">")
            session.setRate(rate)
            say("Speed \(VideoControls.rateLabel(rate))")
        case "N": if session.hasNext { Task { await session.next() } }
        case "P": if session.hasPrevious { Task { await session.previous() } }
        case "?": showsKeys.toggle()
        default: return false
        }
        return true
    }

    func nudgeVolume(_ delta: Float) {
        session.setVolume(session.volume + delta)
        say("Volume \(Int((session.volume * 100).rounded()))%")
    }
}

/// System Picture in Picture on the player's layer.
@MainActor
final class VideoPiP: NSObject, AVPictureInPictureControllerDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onRestore: (() -> Void)?
    private var controller: AVPictureInPictureController?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, isSupported else { return }
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else { controller.startPictureInPicture() }
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onStart?() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { onStop?() }
    }

    /// The PiP window's "back to the app" button.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { onRestore?() }
        completionHandler(true)
    }
}
