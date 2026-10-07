import SwiftUI
import CascadeKit

/// The Playback menu: transport, shuffle and repeat, auto-mix, volume, and the
/// sleep timer. The desktop only has the stock menus, so this is a small step
/// past it.
///
/// Every shortcut carries Option and Command. A bare key (Space, the arrows,
/// J, K, L) as a menu equivalent would be taken from text fields, and the
/// player bar, the video player, the lyrics editor and the miniplayer all bind
/// those keys themselves.
struct PlaybackCommands: Commands {
    let state: AppState
    var body: some Commands {
        CommandMenu("Playback") { PlaybackMenuItems(state: state) }
        // The app menu's Settings, Command-comma, opens the sidebar's Settings.
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { state.settingsRequests += 1 }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// A View rather than loose commands, so the items redraw when the player
/// changes (Play becomes Pause, the checkmarks move).
private struct PlaybackMenuItems: View {
    let state: AppState

    var body: some View {
        if let player = state.player {
            let idle = player.item == nil
            Button(player.isPaused ? "Play" : "Pause") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(idle)
            Button("Next") { Task { await player.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(idle)
            Button("Previous") { Task { await player.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(idle)
            Button("Stop") { Task { await player.stop() } }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(idle)

            Divider()

            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { _ in player.toggleShuffle() }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(repeatTitle(player.repeatMode)) { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("Auto-mix", isOn: Binding(get: { player.autoMix }, set: { player.autoMix = $0 }))
                .keyboardShortcut("a", modifiers: [.command, .option])

            Divider()

            Button("Volume Up") { player.setVolume(player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Volume Down") { player.setVolume(player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Toggle("Mute", isOn: Binding(get: { player.isMuted }, set: { player.setMuted($0) }))
                .keyboardShortcut("m", modifiers: [.command, .shift])

            Divider()

            Menu("Sleep Timer") {
                sleepItem("Off", on: player.sleepTimer == .off) { player.cancelSleepTimer() }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) Minutes") { player.setSleepTimer(minutes: minutes) }
                }
                sleepItem("End of Track", on: player.sleepTimer == .endOfTrack) { player.setSleepTimerAtEndOfTrack() }
                if case .at(let date) = player.sleepTimer {
                    Divider()
                    Text("Pauses at \(date.formatted(date: .omitted, time: .shortened))")
                }
            }
        } else {
            Button("Play") {}.disabled(true)
        }
    }

    private func repeatTitle(_ mode: RepeatMode) -> String {
        switch mode {
        case .none: "Repeat: Off"
        case .all: "Repeat: All"
        case .one: "Repeat: One"
        }
    }

    /// A menu item with a checkmark when it is the timer that is running.
    private func sleepItem(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
    }
}
