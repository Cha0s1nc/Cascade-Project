import SwiftUI
import AppKit
import CascadeKit

/// Plays AppState.videoSession over the whole window while it is set.
struct MacVideoHost: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let session = state.videoSession {
            // Keyed by the session, so a second video starts with fresh chrome.
            MacVideoScreen(session: session) { state.closeVideo() }
                .id(ObjectIdentifier(session))
        }
    }
}

/// The full-window player: the picture, our controls over it (idle-hidden
/// together with the window's traffic lights and the cursor), the key
/// handling, and the keys panel.
struct MacVideoScreen: View {
    let session: VideoSession
    let close: () -> Void
    @State private var controller: MacVideoController

    init(session: VideoSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _controller = State(initialValue: MacVideoController(session: session, close: close))
    }

    var body: some View {
        ZStack {
            Color.black
            VideoPlayerView(session: session)
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
        .ignoresSafeArea()
        .background(WindowReader { controller.attach(to: $0) })
        .onContinuousHover { if case .active = $0 { controller.poke() } }
        .onDisappear { controller.detach() }
        .onChange(of: session.finished) { _, done in if done { close() } }
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
    @ObservationIgnored private var enteredFullscreen = false

    /// Seconds without a mouse move or key before the controls go.
    private static let idleSeconds = 2.5

    init(session: VideoSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
    }

    // MARK: - Window

    func attach(to window: NSWindow) {
        guard self.window == nil else { return }
        self.window = window
        // The main window's toolbar (Music/Video switch, search) is drawn
        // above the content, so it would sit over the picture.
        toolbarWasVisible = window.toolbar?.isVisible
        window.toolbar?.isVisible = false
        // A search field left focused would take the video's keys.
        window.makeFirstResponder(nil)
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
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
        if let toolbarWasVisible { window.toolbar?.isVisible = toolbarWasVisible }
        if enteredFullscreen, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        self.window = nil
    }

    private var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    /// Hidden while the controls are idle, as the desktop's cursor and chrome
    /// are. Fullscreen has its own, auto-hiding, so leave those alone.
    private func applyTrafficLights() {
        guard let window else { return }
        let hidden = !controlsVisible && !isFullscreen
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }

    func requestClose() { close() }

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
        guard let window, event.window === window else { return false }
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
            else { close() }
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
