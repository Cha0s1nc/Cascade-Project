import AppKit
import CascadeKit

/// The Touch Bar: the track label and previous, play/pause, next.
///
/// Built fresh and put on the key window (and NSApplication, the fallback at the end of every
/// responder chain) each time a window becomes key or the app comes back to the front. Set once
/// on NSApplication only, it went blank after a window switch and came back only when a skip
/// made the system redraw it; and its label and button were single views shared by every bar the
/// system built, which a torn-down bar took with it.
@MainActor
final class MacTouchBar: NSObject, NSTouchBarDelegate {
    private static let shared = MacTouchBar()
    private static let label = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.label")
    private static let prev = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.prev")
    private static let play = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.play")
    private static let next = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.next")

    private weak var state: AppState?
    /// The newest bar's label and play button, which `apply` keeps current.
    private weak var title: NSTextField?
    private weak var playButton: NSButton?
    private var lastMedia: MacIntegrations.Media?
    private var observers: [NSObjectProtocol] = []

    static func install(state: AppState) {
        shared.state = state
        shared.reinstall()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            shared.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { shared.reinstall() }
            })
        }
    }

    /// Called from the integrations poll.
    static func update(_ m: MacIntegrations.Media?) { shared.apply(m) }

    private func reinstall() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.label, .flexibleSpace, Self.prev, Self.play, Self.next]
        NSApp.touchBar = bar
        // Panels (the miniplayer) and the main window alike; a text field being edited still
        // shows its own bar first, as it should.
        if let window = NSApp.keyWindow { window.touchBar = bar }
    }

    private func apply(_ m: MacIntegrations.Media?) {
        lastMedia = m
        let text = m.map { "\($0.item.name ?? "")  -  \($0.item.albumArtist ?? $0.item.artists?.first ?? "")" } ?? "Cascade"
        if let title, title.stringValue != text { title.stringValue = text }
        let symbol = (m?.playing ?? false) ? "pause.fill" : "play.fill"
        if let playButton, playButton.image?.accessibilityDescription != (symbol == "pause.fill" ? "Pause" : "Play") {
            playButton.image = Self.image(symbol)
        }
    }

    private static func image(_ symbol: String) -> NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "pause.fill" ? "Pause" : "Play") ?? NSImage()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        func button(_ symbol: String, _ name: String, _ action: Selector) -> NSButton {
            NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(), target: self, action: action)
        }
        switch id {
        case Self.label:
            let label = NSTextField(labelWithString: "Cascade")
            label.lineBreakMode = .byTruncatingTail
            title = label
            item.view = label
        case Self.prev: item.view = button("backward.fill", "Previous", #selector(previous))
        case Self.next: item.view = button("forward.fill", "Next", #selector(skip))
        case Self.play:
            let play = NSButton(image: Self.image("play.fill"), target: self, action: #selector(toggle))
            playButton = play
            item.view = play
        default: return nil
        }
        // Fill the new views in now rather than at the next second's poll.
        apply(lastMedia)
        return item
    }

    @objc private func previous() { if let p = state?.player { Task { await p.previous() } } }
    @objc private func skip() { if let p = state?.player { Task { await p.next() } } }
    @objc private func toggle() {
        if let v = state?.videoSession { v.togglePlayPause() } else { state?.player?.togglePlayPause() }
    }
}
