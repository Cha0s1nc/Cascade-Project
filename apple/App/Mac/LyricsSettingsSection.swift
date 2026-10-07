import SwiftUI
import Translation
import CascadeKit

/// Lyrics settings (the translation switch, the lyrics source, which languages the Mac can
/// translate), embedded by Settings > Lyrics. Everything here writes through the same setters as
/// the Now Playing pill and the Translate button, so the three can never disagree.
struct LyricsSettingsSection: View {
    @Environment(AppState.self) private var state
    @Bindable private var prefs = LyricsPrefs.shared
    @State private var installed: [String] = []
    @State private var missing: [String] = []
    @State private var checked = false

    private var serverMode: Bool { state.serverOnlyLyrics && state.cascadePluginApi != nil }

    var body: some View {
        Section("Lyrics") {
            Picker("Source", selection: Binding(
                get: { prefs.forcedSource.isValid(serverOnly: serverMode) ? prefs.forcedSource : .auto },
                set: { prefs.forcedSource = $0 })) {
                ForEach(LyricsSourceChoice.choices(serverOnly: serverMode), id: \.self) { Text($0.menuLabel).tag($0) }
            }
            Text(LyricsSourceChoice.autoHint(serverOnly: serverMode) + ". The pill in Now Playing changes this too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Translation") {
            Toggle("Translate lyrics", isOn: Binding(get: { prefs.translationEnabled }, set: {
                prefs.translationEnabled = $0
                MacNowPlayingUI.shared.translator.enabledChanged()
            }))
            Text("Shows an English line under songs in other languages, using Apple Translation on this Mac. Nothing is sent anywhere. Off hides the Translate button.")
                .font(.caption).foregroundStyle(.secondary)
            if prefs.translationEnabled {
                if checked {
                    if !installed.isEmpty {
                        Text("Installed in macOS (\(installed.count)): \(installed.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !missing.isEmpty {
                        Text("Not installed: \(missing.joined(separator: ", ")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Open Language & Region") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .task(id: prefs.translationEnabled) { await refreshLanguages() }
    }

    /// Every language Apple takes, not only the ones System Settings lists: macOS's multilingual
    /// model covers languages it never shows as downloaded, so this asks the framework.
    private func refreshLanguages() async {
        guard prefs.translationEnabled else { return }
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en")
        var have: [String] = [], need: [String] = []
        for key in LyricLanguages.appleKeys {
            switch await availability.status(from: Locale.Language(identifier: key), to: english) {
            case .installed: have.append(key)
            case .supported: need.append(key)
            default: break
            }
        }
        installed = have.map(LyricLanguages.displayName).sorted()
        missing = need.map(LyricLanguages.displayName).sorted()
        checked = true
    }
}
