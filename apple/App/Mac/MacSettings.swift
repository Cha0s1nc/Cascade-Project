import SwiftUI
import CascadeKit

/// The one path each shared setting goes through. Settings and the first-run
/// wizard both call these rather than each persisting a value themselves, so
/// there is nowhere for the two to drift apart (renderer.js's setCrossfadeEnabled
/// and friends).
@MainActor
enum SettingsActions {
    /// 0 is off, otherwise the fade's length (CascadeKit's range, 1 to 15).
    static func setCrossfade(seconds: Int, state: AppState) {
        let s = Crossfade.range.contains(seconds) ? seconds : 0
        state.player?.crossfadeSeconds = Double(s)
        UserDefaults.standard.set(s, forKey: "cascade.crossfadeSeconds")
    }

    static func setQuality(_ quality: StreamingQuality, state: AppState) {
        let cellular = state.player?.cellularQuality ?? StreamingQuality(stored: UserDefaults.standard.object(forKey: StreamingQuality.cellularKey))
        UserDefaults.standard.set(quality.rawValue, forKey: StreamingQuality.wifiKey)
        UserDefaults.standard.set(cellular.rawValue, forKey: StreamingQuality.cellularKey)
        state.player?.setStreamingQuality(wifi: quality, cellular: cellular)
    }

    static func setNormalization(_ mode: Normalization.Mode, state: AppState) {
        state.player?.normalization = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "cascade.normalization")
    }

    /// Whether lyric translation exists at all. Only an explicit off switches it
    /// off; missing or corrupt means on, as on the desktop.
    static var lyricsTranslationEnabled: Bool {
        UserDefaults.standard.object(forKey: "cascade.lyricsTranslationEnabled") as? Bool ?? true
    }

    static func setLyricsTranslation(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "cascade.lyricsTranslationEnabled")
    }

    /// `cascade.theme` is the Electron blob, `{mode, gradStart, gradEnd, albumArt}`
    /// as a JSON string. A change here keeps every other field as it was.
    static func theme() -> (mode: String, albumArt: Bool) {
        let t = themeBlob()
        return (t["mode"] as? String == "light" ? "light" : "dark", t["albumArt"] as? Bool ?? false)
    }

    static func setTheme(mode: String? = nil, albumArt: Bool? = nil) {
        var t = themeBlob()
        if let mode { t["mode"] = mode == "light" ? "light" : "dark" }
        if let albumArt { t["albumArt"] = albumArt }
        if let data = try? JSONSerialization.data(withJSONObject: t, options: [.sortedKeys]) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "cascade.theme")
        }
    }

    private static func themeBlob() -> [String: Any] {
        guard let raw = UserDefaults.standard.string(forKey: "cascade.theme"),
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return [:] }
        return object
    }
}

/// The six-tab Settings, shown by the Settings scene and the sidebar entry.
struct MacSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case library, playback, lyrics, integrations, account, about
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .library: "books.vertical"
            case .playback: "play.circle"
            case .lyrics: "text.quote"
            case .integrations: "puzzlepiece.extension"
            case .account: "person.crop.circle"
            case .about: "info.circle"
            }
        }
    }

    @SceneStorage("mac.settingsTab") private var tab: Tab = .library
    @FocusState private var tabsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .library: LibraryTab()
                case .playback: PlaybackTab()
                case .lyrics: LyricsTab()
                case .integrations: IntegrationsTab()
                case .account: AccountTab()
                case .about: AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 580)
        .onAppear {
            tabsFocused = true
            #if DEBUG
            // Test hook for looking at a tab without clicking: `-cascade.settingsTab playback`.
            if let raw = UserDefaults.standard.string(forKey: "cascade.settingsTab"), let t = Tab(rawValue: raw) { tab = t }
            #endif
        }
    }

    /// Arrow keys move between tabs while the strip has focus, as the desktop's
    /// tab list does; Command-1 to 6 jump straight to one.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(Tab.allCases.enumerated()), id: \.element) { index, item in
                Button { tab = item; tabsFocused = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 17))
                        Text(item.title).font(.caption)
                    }
                    .frame(width: 84, height: 44)
                    .background(tab == item ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .focusable()
        .focused($tabsFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let all = Tab.allCases
        guard let i = all.firstIndex(of: tab) else { return .ignored }
        tab = all[(i + delta + all.count) % all.count]
        return .handled
    }
}

// MARK: - Library

private struct LibraryTab: View {
    var body: some View {
        Form {
            LibrarySettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playback

private struct PlaybackTab: View {
    @Environment(AppState.self) private var state
    @State private var crossfade = 0
    @State private var crossfadeLength = 6

    var body: some View {
        Form {
            if let player = state.player {
                Section {
                    Picker("Streaming quality", selection: Binding(get: { player.streamingQuality }, set: { SettingsActions.setQuality($0, state: state) })) {
                        ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Volume normalization", selection: Binding(get: { player.normalization }, set: { SettingsActions.setNormalization($0, state: state) })) {
                        Text("Off").tag(Normalization.Mode.off)
                        Text("By Track").tag(Normalization.Mode.track)
                        Text("By Album").tag(Normalization.Mode.album)
                    }
                    Toggle("Crossfade", isOn: Binding(get: { crossfade > 0 }, set: { on in
                        crossfade = on ? crossfadeLength : 0
                        SettingsActions.setCrossfade(seconds: crossfade, state: state)
                    }))
                    if crossfade > 0 {
                        LabeledContent("Length") {
                            HStack {
                                Slider(value: Binding(get: { Double(crossfadeLength) }, set: {
                                    crossfadeLength = Int($0.rounded())
                                    crossfade = crossfadeLength
                                    SettingsActions.setCrossfade(seconds: crossfadeLength, state: state)
                                }), in: Double(Crossfade.range.lowerBound)...Double(Crossfade.range.upperBound), step: 1)
                                    .frame(width: 180)
                                    .accessibilityLabel("Crossfade length")
                                Text("\(crossfadeLength) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Below the original, the server converts to AAC at that rate; it applies from the next track. Normalization evens out loudness using the server's scan (Jellyfin's LUFS scan has to be on); By Album keeps an album's own dynamics. Crossfade blends the end of each song into the next; off keeps albums gapless.")
                }

                OutputDeviceSettings()
                RadioSettingsSection()

                Section {
                    EQPanel(title: "Music", profile: Binding(get: { state.equalizer(for: .music) }, set: { state.setEqualizer($0, for: .music) }))
                } header: {
                    Text("Equalizer")
                } footer: {
                    Text("Works on songs streamed at Original quality and on downloads; a lower streaming quality plays flat. While it is on, quiet tracks are also turned up by volume normalization. It costs gapless playback: expect a short pause, about a quarter second, between tracks.")
                }
                Section {
                    EQPanel(title: "Video", profile: Binding(get: { state.equalizer(for: .video) }, set: { state.setEqualizer($0, for: .video) }))
                } footer: {
                    Text("Its own curve for movies and shows, so a music preset does not follow you into a film.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            crossfade = Int(state.player?.crossfadeSeconds ?? 0)
            if crossfade > 0 { crossfadeLength = crossfade }
        }
    }
}

// MARK: - Lyrics

private struct LyricsTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            // Only with the plugin: without it, server-only would mean no
            // lyrics at all, so the waterfall runs whatever this says.
            if state.cascadePluginApi != nil {
                Section {
                    Toggle("Server-only lyrics", isOn: $state.serverOnlyLyrics)
                } footer: {
                    Text(state.serverOnlyLyrics
                         ? "Lyrics come only from Cascade Server: Spicy Lyrics, then lyrics saved on the server."
                         : "Cascade also asks Kugou, LRCLIB and Jellyfin, which sends each song's title and artist to Kugou and LRCLIB.")
                }
            }
            LyricsSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Integrations

private struct IntegrationsTab: View {
    var body: some View {
        Form {
            DiscordSettingsSection()
            WaterfallSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

private struct AccountTab: View {
    @Environment(AppState.self) private var state
    @State private var username: String?
    @State private var confirmingSignOut = false

    @State private var quickConnectEnabled = false
    @State private var approveCode = ""
    @State private var isApproving = false
    @State private var approveStatus: (ok: Bool, message: String)?

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var repeatPassword = ""
    @State private var isChanging = false
    @State private var passwordStatus: (ok: Bool, message: String)?

    private var passwordProblem: String? {
        if newPassword.isEmpty { return nil }
        return newPassword == repeatPassword ? nil : "The new passwords do not match."
    }

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Server", value: state.config?.url ?? "")
                LabeledContent("Signed in as", value: username ?? "")
            }

            Section {
                SecureField("Current password", text: $currentPassword)
                SecureField("New password", text: $newPassword)
                SecureField("Repeat new password", text: $repeatPassword)
                    .onSubmit { changePassword() }
                HStack {
                    Button(isChanging ? "Changing\u{2026}" : "Change Password") { changePassword() }
                        .disabled(isChanging || newPassword.isEmpty || passwordProblem != nil)
                    if let message = passwordProblem ?? passwordStatus?.message {
                        Text(message).font(.caption)
                            .foregroundStyle(passwordProblem == nil && passwordStatus?.ok == true ? Color.green : Color.red)
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                Text("Changes the password on the server. This device stays signed in; other devices keep their sessions until they sign out.")
            }

            if quickConnectEnabled {
                Section {
                    TextField("Code", text: $approveCode)
                        .accessibilityIdentifier("approveCode")
                        .onSubmit { approve() }
                    HStack {
                        Button(isApproving ? "Approving\u{2026}" : "Approve") { approve() }
                            .disabled(isApproving || QuickConnect.normalizedCode(approveCode) == nil)
                        if let approveStatus {
                            Text(approveStatus.message).font(.caption).foregroundStyle(approveStatus.ok ? Color.green : Color.red)
                        }
                    }
                } header: {
                    Text("Approve a Device")
                } footer: {
                    Text("Signs another device in as you. Enter the Quick Connect code it shows.")
                }
            }

            Section {
                Button("Sign Out", role: .destructive) { confirmingSignOut = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await state.signOut() } }
        }
        .task {
            guard let client = state.client else { return }
            username = state.username
            if username == nil, let userId = state.config?.userId, let me: JfAuthUser = try? await client.get("/Users/\(userId)") {
                username = me.name
                state.username = me.name
            }
            if let url = state.config?.url { quickConnectEnabled = await QuickConnect.isEnabled(serverUrl: url) }
        }
    }

    /// Guarded here as well as disabled: a disabled button is not the only way
    /// in (return key, accessibility actions).
    private func approve() {
        guard !isApproving, let code = QuickConnect.normalizedCode(approveCode), let client = state.client else { return }
        isApproving = true
        approveStatus = nil
        Task {
            do {
                try await client.authorizeQuickConnect(code: code)
                approveStatus = (true, "Approved. The other device is signing in.")
                approveCode = ""
            } catch {
                approveStatus = (false, error.localizedDescription)
            }
            isApproving = false
        }
    }

    private func changePassword() {
        guard !isChanging, !newPassword.isEmpty, passwordProblem == nil, let client = state.client else { return }
        isChanging = true
        passwordStatus = nil
        let (current, new) = (currentPassword, newPassword)
        Task {
            do {
                try await client.changePassword(current: current, new: new)
                passwordStatus = (true, "Password changed.")
                currentPassword = ""; newPassword = ""; repeatPassword = ""
            } catch {
                passwordStatus = (false, error.localizedDescription)
            }
            isChanging = false
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @Environment(AppState.self) private var state
    @State private var beta = UpdateService.shared.betaChannel
    @State private var confirmingSwitch = false
    private let updates = UpdateService.shared

    private var statusText: String {
        switch updates.status {
        case .idle: ""
        case .checking: "Checking\u{2026}"
        case .upToDate: "Cascade is up to date."
        case .available(let v): "Version \(v) is available."
        case .failed(let message): "Could not check: \(message)"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: state.appVersion)
                LabeledContent("Build", value: "Native Mac")
            }
            Section {
                Toggle("Beta updates", isOn: Binding(get: { beta }, set: {
                    beta = $0
                    UserDefaults.standard.set($0, forKey: "cascade.betaUpdates")
                }))
                HStack {
                    Button("Check for Updates") { Task { await updates.check(manual: true) } }
                        .disabled(updates.status == .checking)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Beta builds arrive first and may be rough. A beta build follows the beta channel unless you turn it off here.")
            }
            Section {
                Button("Switch back to the Electron build\u{2026}") { confirmingSwitch = true }
                    .disabled(updates.status == .checking)
            } header: {
                Text("Electron build")
            } footer: {
                #if DEBUG
                Text("Replaces this app with the Electron build and carries your settings across. Debug builds do not write the Electron settings file unless CASCADE_ELECTRON_CONFIG points at one.")
                #else
                Text("Replaces this app with the Electron build and carries your settings across.")
                #endif
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Switch to the Electron build?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
            Button("Download the Electron Build") { Task { await updates.prepareSwitchBack() } }
        } message: {
            Text("Cascade will download the Electron build, save your settings for it, and replace this app.")
        }
    }
}
