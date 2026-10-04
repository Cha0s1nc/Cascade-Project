import SwiftUI
import AppKit
import CascadeKit

/// State shared by the overlay, the side lyrics panel and the player bar: which half of the
/// overlay shows, whether the side panel is open, the one lyrics model both panels read (so a
/// song's lyrics are asked for once) and the translator. In-session, like the desktop's
/// overlayLyricsOpen.
@MainActor
@Observable
final class MacNowPlayingUI {
    static let shared = MacNowPlayingUI()

    enum RightPanel { case queue, lyrics }
    var rightPanel = RightPanel.queue
    var sidePanelOpen = false
    var historyOpen = false
    /// Bumped by "Reload lyrics", so the load runs again for a source that was only down.
    var reloadTick = 0
    /// The Link a Spotify Track sheet is up.
    var linkingSpotify = false

    let lyrics = LyricsModel()
    let translator = LyricsTranslator()

    private init() {}
}

/// The one-time "this needs the Cascade Server plugin" notice the desktop shows before the
/// lyrics editor (and anything else that only the plugin can do). Accepted once, never again.
/// The editor window (agent N2) calls `PluginNotice.ensure()` before it opens.
@MainActor
enum PluginNotice {
    /// True when the person may go on: already accepted, or just accepted now.
    static func ensure() -> Bool {
        let prefs = LyricsPrefs.shared
        if prefs.pluginNoticeSeen { return true }
        let alert = NSAlert()
        alert.messageText = "Cascade Server Plugin Required"
        alert.informativeText = """
        This feature requires the Cascade Server plugin installed on your Jellyfin server.

        The plugin enables server-side karaoke lyric storage, the lyrics editor, and server-only mode.
        """
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        prefs.pluginNoticeSeen = true
        return true
    }
}

// MARK: - The lyrics themselves

/// What a lyrics panel shows for the playing song: the lines (with translations under them while
/// those are on), a spinner while they load, or why there are none.
struct MacLyricsBody: View {
    let player: PlaybackService
    @Environment(AppState.self) private var state
    private var ui: MacNowPlayingUI { .shared }

    var body: some View {
        let model = ui.lyrics
        if let lines = model.lines {
            VStack(spacing: 8) {
                LyricsView(lines: lines, player: player, emphasis: model.credit != nil, synced: model.synced,
                           translations: ui.translator.showing ? ui.translator.translations : nil)
                    // A new song's lyrics start from their own top, not scrolled to wherever
                    // the last song's were.
                    .id(player.item?.id)
                // Pinned under the lyrics, with the controls or without: SpicyLyrics' terms want
                // it visible, not tucked away.
                if let credit = model.credit { LyricsCreditView(credit: credit) }
            }
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Text(model.instrumental ? "This track is instrumental" : "No lyrics available")
                    .foregroundStyle(.secondary)
                if !model.instrumental, state.cascadePluginInfo.spotifyLink, player.item != nil {
                    Button("Link a Spotify track") { ui.linkingSpotify = true }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The source pill and its dropdown: Auto, or force Kugou, LRCLIB or Jellyfin (Karaoke Only or
/// Synced Only in server-only mode), each with how it went on the last fetch. Shows the forced
/// source, else where the lyrics on screen came from.
struct LyricsSourcePill: View {
    @Environment(AppState.self) private var state
    private var ui: MacNowPlayingUI { .shared }
    private var prefs: LyricsPrefs { .shared }

    private var serverMode: Bool { state.serverOnlyLyrics && state.cascadePluginApi != nil }

    var body: some View {
        let forced = prefs.forcedSource.isValid(serverOnly: serverMode) ? prefs.forcedSource : .auto
        let label = forced == .auto ? (ui.lyrics.source ?? "Auto") : forced.label
        Menu {
            ForEach(LyricsSourceChoice.choices(serverOnly: serverMode), id: \.self) { choice in
                Button {
                    if prefs.forcedSource != choice { prefs.forcedSource = choice }
                } label: {
                    Label(title(choice), systemImage: forced == choice ? "checkmark" : symbol(choice))
                }
                .help(tooltip(choice))
            }
            Divider()
            Button("Reload Lyrics", systemImage: "arrow.clockwise") {
                ui.lyrics.reload()
                ui.reloadTick += 1
            }
            if state.cascadePluginInfo.spotifyLink, state.player?.item != nil {
                Button(ui.lyrics.credit != nil ? "Change Spotify Track\u{2026}" : "Link a Spotify Track\u{2026}",
                       systemImage: "link") { ui.linkingSpotify = true }
            }
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(forced == .auto ? Color.primary.opacity(0.1) : Color.accentColor.opacity(0.3)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Lyrics source")
        .accessibilityLabel("Lyrics source")
        .accessibilityValue(label)
    }

    private func title(_ choice: LyricsSourceChoice) -> String {
        choice == .auto ? "Auto \u{2014} \(LyricsSourceChoice.autoHint(serverOnly: serverMode))" : choice.menuLabel
    }

    /// The badge for how the source went on the last fetch.
    private func symbol(_ choice: LyricsSourceChoice) -> String {
        guard let key = choice.statusKey, let status = ui.lyrics.tried[key] else { return "circle.dashed" }
        return status == .ok ? "checkmark.circle" : "xmark.circle"
    }

    private func tooltip(_ choice: LyricsSourceChoice) -> String {
        guard let key = choice.statusKey, let status = ui.lyrics.tried[key] else { return "" }
        return status == .ok ? "Succeeded last fetch" : "Failed last fetch"
    }
}

/// The Translate button: shown only for a sheet something here can translate. "Translate",
/// "Show original", progress while it runs, and the install prompt when the language is not
/// installed in macOS yet.
struct TranslateButton: View {
    var compact = false
    private var translator: LyricsTranslator { MacNowPlayingUI.shared.translator }

    var body: some View {
        if translator.offered {
            Button { translator.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "character.bubble")
                    if !compact { Text(label) }
                }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(translator.showing ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel("Translate lyrics")
            .accessibilityValue(translator.showing ? "On" : "Off")
        }
    }

    private var label: String {
        switch translator.status {
        case .translating(let done, let total) where total > 0: "\(Int(Double(done) / Double(total) * 100))%"
        case .translating: "Translating\u{2026}"
        case .needsInstall(let key): "Install \(LyricTranslation.displayName(key))\u{2026}"
        case .failed: "Failed"
        case .idle: translator.showing ? "Show original" : "Translate"
        }
    }

    private var help: String {
        switch translator.status {
        case .failed: "Translation unavailable"
        case .needsInstall(let key): "Install \(LyricTranslation.displayName(key)) in macOS to translate"
        default: translator.showing ? "Show original" : "Translate lyrics"
        }
    }
}

/// Everything above a lyrics panel's lines: the source pill and the Translate button.
struct LyricsPanelHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            LyricsSourcePill()
            Spacer()
            TranslateButton()
        }
    }
}

// MARK: - The side panel

/// The lyrics panel that floats over whatever view is on screen, opened from the player bar:
/// the desktop's fixed `.lyrics-panel`. A narrow strip, so the lyrics run smaller than in Now
/// Playing.
struct SideLyricsPanel: View {
    let player: PlaybackService
    private var ui: MacNowPlayingUI { .shared }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Lyrics").font(.headline)
                Spacer()
                Button { ui.sidePanelOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close lyrics")
                    .accessibilityLabel("Close lyrics")
            }
            LyricsPanelHeader()
            MacLyricsBody(player: player)
                .environment(\.lyricScale, 0.62)
        }
        .padding(14)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
        // Clear of the toolbar above and the player bar below.
        .padding(.top, 56)
        .padding(.bottom, 84)
        .padding(.trailing, 12)
    }
}
