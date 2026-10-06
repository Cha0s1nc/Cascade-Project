import AppKit
import CascadeKit

/// The Touch Bar: the track label and previous, play/pause, next. Set on NSApplication, which
/// ends every responder chain, so it shows whichever window is key (main window, miniplayer).
@MainActor
final class MacTouchBar: NSObject, NSTouchBarDelegate {
    private static let shared = MacTouchBar()
    private static let label = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.label")
    private static let prev = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.prev")
    private static let play = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.play")
    private static let next = NSTouchBarItem.Identifier("xyz.chaosinc.cascade.tb.next")

    private weak var state: AppState?
    private let title = NSTextField(labelWithString: "Cascade")
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private var lastPlaying: Bool?

    static func install(state: AppState) {
        shared.state = state
        let bar = NSTouchBar()
        bar.delegate = shared
        bar.defaultItemIdentifiers = [label, .flexibleSpace, prev, play, next]
        NSApp.touchBar = bar
    }

    /// Called from the integrations poll.
    static func update(_ m: MacIntegrations.Media?) { shared.apply(m) }

    private func apply(_ m: MacIntegrations.Media?) {
        let text = m.map { "\($0.item.name ?? "")  -  \($0.item.albumArtist ?? $0.item.artists?.first ?? "")" } ?? "Cascade"
        if title.stringValue != text { title.stringValue = text }
        let playing = m?.playing ?? false
        if playing != lastPlaying {
            lastPlaying = playing
            playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        func button(_ symbol: String, _ name: String, _ action: Selector) -> NSButton {
            NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage(), target: self, action: action)
        }
        switch id {
        case Self.label:
            title.lineBreakMode = .byTruncatingTail
            item.view = title
        case Self.prev: item.view = button("backward.fill", "Previous", #selector(previous))
        case Self.next: item.view = button("forward.fill", "Next", #selector(skip))
        case Self.play:
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            playButton.target = self
            playButton.action = #selector(toggle)
            item.view = playButton
        default: return nil
        }
        return item
    }

    @objc private func previous() { if let p = state?.player { Task { await p.previous() } } }
    @objc private func skip() { if let p = state?.player { Task { await p.next() } } }
    @objc private func toggle() {
        if let v = state?.videoSession { v.togglePlayPause() } else { state?.player?.togglePlayPause() }
    }
}
