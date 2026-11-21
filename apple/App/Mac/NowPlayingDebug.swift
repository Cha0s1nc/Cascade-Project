#if DEBUG
import SwiftUI
import CascadeKit

/// Drives Now Playing without a person, for checking a build against the local test server
/// when no UI scripting is allowed: launch with `-cascade.debugNP play,open,lyrics` (a comma list
/// run in order, once the player exists). Debug builds only, and it does nothing without the
/// argument.
///
/// play: plays 24 songs from the library. load: queues them paused at the fourth, as a
/// restored queue (nothing plays; it does save the queue as the last one). open: opens the overlay. lyrics, queue: the right
/// half. side: the side lyrics panel. light, dark: the mode. art: album-art accent on. idle:
/// no-op placeholder to read as "leave it". theme: nothing (the popover needs a click).
@MainActor
enum NowPlayingDebug {
    static func run(_ state: AppState) async {
        guard let script = UserDefaults.standard.string(forKey: "cascade.debugNP"), !script.isEmpty else { return }
        for _ in 0..<100 where state.player == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let player = state.player, let client = state.client else { return }
        let ui = MacNowPlayingUI.shared
        for step in script.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch step {
            case "play":
                if let songs = try? await client.songs(limit: 24) { await player.play(songs) }
                try? await Task.sleep(for: .seconds(1.5))
            case "load":
                if let songs = try? await client.songs(limit: 24), songs.count > 3 {
                    player.adoptRestoredQueue(RestoredQueue(queue: songs, index: 3, positionSec: 30, unshuffled: []),
                                              shuffled: false, repeatMode: player.repeatMode)
                }
            case "open": state.nowPlayingOpen = true
            case "lyrics": ui.rightPanel = .lyrics
            case "queue": ui.rightPanel = .queue
            case "side": ui.sidePanelOpen = true
            case "light": MacTheme.shared.settings.mode = .light
            case "dark": MacTheme.shared.settings.mode = .dark
            case "art": MacTheme.shared.settings.albumArt = true
            case "history": ui.historyOpen = true
            default: break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
}
#endif
