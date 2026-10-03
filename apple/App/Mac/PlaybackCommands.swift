import SwiftUI
import CascadeKit

// Owner: playback agent (P). Stub from the contract in apple/MAC-MAP.md; replace freely.
/// The Playback menu.
struct PlaybackCommands: Commands {
    let state: AppState
    var body: some Commands { CommandMenu("Playback") {} }
}
