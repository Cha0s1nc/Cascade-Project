import SwiftUI
import CascadeKit

/// Discord status, embedded by Settings > Integrations.
struct DiscordSettingsSection: View {
    @State private var enabled = MacIntegrations.discordEnabled
    @State private var clientId = MacIntegrations.discordClientId

    var body: some View {
        let discord = MacIntegrations.discord
        Section("Discord") {
            Toggle("Show what I'm playing on Discord", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    UserDefaults.standard.set(on, forKey: MacIntegrations.discordEnabledKey)
                    MacIntegrations.applyDiscordSettings()
                }
            HStack {
                Text("Status")
                Spacer()
                Circle().fill(discord.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(discord.connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
            }
            TextField("Client ID", text: $clientId, prompt: Text(DiscordClient.defaultClientId))
                .onSubmit {
                    let id = clientId.trimmingCharacters(in: .whitespaces)
                    // Same shape the desktop accepts: digits only.
                    if id.isEmpty || (id.count >= 5 && id.count <= 32 && id.allSatisfy(\.isNumber)) {
                        UserDefaults.standard.set(id, forKey: MacIntegrations.discordClientIdKey)
                        MacIntegrations.applyDiscordSettings()
                    } else { clientId = MacIntegrations.discordClientId }
                }
            Text("Leave the client ID empty to use Cascade's own application. Discord has to be running on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Starts the Mac-only integrations (Discord, control server, Touch Bar,
/// debug panel) once the app has its state.
@MainActor
enum MacIntegrations {
    /// What is on, from the music player or the video session.
    struct Media {
        var item: JfItem
        var playing: Bool
        var position: Double
        var duration: Double?
        var video: Bool
    }

    static let discord = DiscordClient()
    static let discordEnabledKey = "cascade.discordRpcEnabled"
    static let discordClientIdKey = "cascade.discordClientId"
    static var discordEnabled: Bool {
        let v = UserDefaults.standard.object(forKey: discordEnabledKey)
        return (v as? Bool) ?? ((v as? String) == "true")
    }
    static var discordClientId: String { UserDefaults.standard.string(forKey: discordClientIdKey) ?? "" }

    static func applyDiscordSettings() { discord.configure(enabled: discordEnabled, clientId: discordClientId) }

    private static var started = false
    /// The last track seen, kept after it stops, which is what /cascade/now-playing reports.
    private static var lastTrack = ControlNowPlaying.empty

    static func start(state: AppState) {
        // One per process: onAppear fires for every main window that opens.
        guard !started else { return }
        started = true
        ControlServer.shared.start(state: state)
        MacTouchBar.install(state: state)
        DebugPanel.showIfEnabled(state: state)
        EscapeKeys.install(state: state)
        // ponytail: one poll a second feeds Discord, the Touch Bar and the control cache instead of
        // observing four sources. The Discord throttle is 5 s anyway. Observe if it ever shows in a profile.
        Task {
            while !Task.isCancelled {
                tick(state)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func current(_ state: AppState) -> Media? {
        if let v = state.videoSession, let item = v.item {
            return Media(item: item, playing: v.isPlaying, position: v.position, duration: nil, video: true)
        }
        guard let p = state.player, let item = p.item else { return nil }
        return Media(item: item, playing: !p.isPaused, position: p.livePositionSeconds,
                     duration: p.durationSeconds > 0 ? p.durationSeconds : nil, video: false)
    }

    private static func tick(_ state: AppState) {
        applyDiscordSettings()
        let media = current(state)
        discord.present(media)
        MacTouchBar.update(media)
        if let media { lastTrack = nowPlaying(media) } else { lastTrack.isPlaying = false }
    }

    /// The Cha0s Stream document. Ids rather than an art URL: a URL here would carry this session's token.
    static func nowPlaying(_ m: Media) -> ControlNowPlaying {
        let i = m.item
        let ticks = i.runTimeTicks.map { $0 / 10_000 } ?? m.duration.map { Int($0 * 1000) }
        return ControlNowPlaying(title: i.name ?? "", artist: i.albumArtist ?? i.artists?.first ?? "", album: i.album ?? "",
                                 trackId: i.id, artItemId: i.albumId ?? i.id,
                                 artImageTag: i.albumPrimaryImageTag ?? i.imageTags?.primary ?? "",
                                 durationMs: ticks, positionMs: Int(m.position * 1000), isPlaying: m.playing)
    }

    /// Fresh at request time, so a poll of /cascade/now-playing sees the live position.
    static func nowPlayingSnapshot(_ state: AppState) -> ControlNowPlaying {
        if let m = current(state) { return nowPlaying(m) }
        return lastTrack
    }
}

/// Esc closes what is open, innermost first. A text field, a sheet, a popover or a menu keeps its
/// own Esc, and the overlay and the video player close themselves (NowPlayingOverlay, MacVideo),
/// so this only handles the Now Playing history and side lyrics panels, which had no Esc of their own.
@MainActor
enum EscapeKeys {
    private static var monitor: Any?

    static func install(state: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            // ponytail: swallowed only when a panel is really closed; everything else falls through untouched.
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let w = event.window, !(w is NSPanel), w.attachedSheet == nil, !(w.firstResponder is NSText) else { return false }
                let ui = MacNowPlayingUI.shared
                if ui.historyOpen { ui.historyOpen = false; return true }
                if !state.nowPlayingOpen, ui.sidePanelOpen { ui.sidePanelOpen = false; return true }
                return false
            }
            return closed ? nil : event
        }
    }
}
