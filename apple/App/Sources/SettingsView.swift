import SwiftUI
import CascadeKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var libraries: [JfItem] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmingSignOut = false
    @State private var username: String?
    @State private var quickConnectEnabled = false
    @State private var approveCode = ""
    @State private var isApproving = false
    @State private var approveStatus: (ok: Bool, message: String)?
    @AppStorage("cascade.autoSkipSegments") private var autoSkipSegments = false

    var body: some View {
        #if os(macOS)
        // The Mac's Settings is the six-tab one, wherever it is opened from.
        MacSettingsView()
        #else
        phoneBody
        #endif
    }

    @ViewBuilder private var phoneBody: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: state.config?.url ?? "")
                LabeledContent("Signed in as", value: username ?? "")
            }

            ProxySettingsSection()

            Section {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: libraries.isEmpty)
                ForEach(libraries) { library in
                    Toggle(library.name ?? "Unknown", isOn: Binding(
                        get: { isOn(library.id) },
                        set: { setEnabled(library.id, $0) }
                    ))
                    // The last library cannot be switched off: with nothing
                    // left there is nothing to browse.
                    .disabled(isOn(library.id) && enabledCount == 1)
                }
            } header: {
                Text("Libraries")
            } footer: {
                Text(selected.isEmpty
                     ? "Showing all libraries."
                     : "Showing \(selected.count) of \(libraries.count) libraries.")
            }

            if let player = state.player {
                Section {
                    Picker(qualityTitle, selection: Binding(
                        get: { player.streamingQuality },
                        set: { setQuality(wifi: $0, cellular: player.cellularQuality) }
                    )) {
                        ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                    }
                    #if os(iOS)
                    Picker("On Cellular", selection: Binding(
                        get: { player.cellularQuality },
                        set: { setQuality(wifi: player.streamingQuality, cellular: $0) }
                    )) {
                        ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                    }
                    #endif
                    Picker("Volume Normalization", selection: Binding(
                        get: { player.normalization },
                        set: {
                            player.normalization = $0
                            UserDefaults.standard.set($0.rawValue, forKey: "cascade.normalization")
                        }
                    )) {
                        Text("Off").tag(Normalization.Mode.off)
                        Text("By Track").tag(Normalization.Mode.track)
                        Text("By Album").tag(Normalization.Mode.album)
                    }
                    Picker("Crossfade", selection: Binding(
                        get: { Int(player.crossfadeSeconds) },
                        set: {
                            player.crossfadeSeconds = Double($0)
                            UserDefaults.standard.set($0, forKey: "cascade.crossfadeSeconds")
                        }
                    )) {
                        Text("Off").tag(0)
                        ForEach(Array(Crossfade.range), id: \.self) { Text("\($0) s").tag($0) }
                    }
                    NavigationLink {
                        EqualizerView()
                    } label: {
                        LabeledContent("Equalizer", value: player.equalizer.enabled
                                       ? player.equalizer.presetName ?? "Custom" : "Off")
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Below the original, the server converts to AAC at that rate. Applies from the next track.\n\nNormalization evens out loudness using the server's scan (Jellyfin's LUFS scan has to be on). By Album keeps an album's own dynamics. Loud tracks are turned down; quiet ones are turned up only while the equalizer is on.\n\nCrossfade blends the end of each song into the next; off keeps albums gapless.")
                }
            }

            Section {
                Toggle("Auto-Skip Intros and Credits", isOn: $autoSkipSegments)
            } header: {
                Text("Video")
            } footer: {
                Text("Skips an intro or the end credits as soon as it starts, once each. Needs Jellyfin 10.10 or later with something that finds them, such as the Intro Skipper plugin. The Skip button still shows when this is off.")
            }

            // Only with the plugin: without it, server-only would mean no
            // lyrics at all, so the waterfall runs whatever this says.
            if state.cascadePluginApi != nil {
                @Bindable var state = state
                Section {
                    Toggle("Server-Only Lyrics", isOn: $state.serverOnlyLyrics)
                } header: {
                    Text("Lyrics")
                } footer: {
                    Text(state.serverOnlyLyrics
                         ? "Lyrics come only from Cascade Server: Spicy Lyrics, then lyrics saved on the server."
                         : "Cascade also asks Kugou, LRCLIB and Jellyfin, which sends each song's title and artist to Kugou and LRCLIB.")
                }
            }

            if quickConnectEnabled {
                Section {
                    TextField("Code", text: $approveCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("approveCode")
                        .onSubmit { approve() }
                    Button(isApproving ? "Approving\u{2026}" : "Approve") { approve() }
                        .disabled(isApproving || QuickConnect.normalizedCode(approveCode) == nil)
                    if let approveStatus {
                        Text(approveStatus.message)
                            .font(.caption)
                            .foregroundStyle(approveStatus.ok ? Color.green : Color.red)
                    }
                } header: {
                    Text("Approve a Device")
                } footer: {
                    Text("Signs another device in as you. Enter the Quick Connect code it shows.")
                }
            }

            Section {
                @Bindable var state = state
                Picker("Browse", selection: $state.browseMode) {
                    Text("Music").tag(AppState.BrowseMode.music)
                    Text("Movies and Shows").tag(AppState.BrowseMode.video)
                }
            } footer: {
                Text("Which library the tabs show.")
            }

            Section {
                NavigationLink {
                    WaterfallView()
                } label: {
                    LabeledContent("Waterfall", value: state.waterfall?.isActive == true
                                   ? (state.waterfall?.role == .host ? "Hosting" : "In a Room") : "Off")
                }
            } footer: {
                Text("Listen along with others on this server.")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmingSignOut = true
                }
            }

            Section("About") {
                LabeledContent("Edition", value: cascadeEdition)
                LabeledContent("Version", value: state.appVersion)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await state.signOut() }
            }
        }
        .task {
            guard let client = state.client else { return }
            selected = Set(state.config?.libraryIds ?? [])
            username = state.username
            if username == nil, let userId = state.config?.userId,
               let me: JfAuthUser = try? await client.get("/Users/\(userId)") {
                username = me.name
                state.username = me.name
            }
            // Every music library, not musicLibraries(): that one is filtered
            // to the current selection, so after picking one library the
            // others vanished from this list and could never be picked again.
            if let url = state.config?.url {
                quickConnectEnabled = await QuickConnect.isEnabled(serverUrl: url)
            }
            do { libraries = try await client.views().filter { $0.collectionType == "music" } }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    /// Guarded here as well as disabled: a disabled button is not the only
    /// way in (return key, accessibility actions).
    private func approve() {
        guard !isApproving, let code = QuickConnect.normalizedCode(approveCode),
              let client = state.client else { return }
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

    #if os(iOS)
    private let qualityTitle = "On Wi-Fi"
    #else
    private let qualityTitle = "Streaming Quality"
    #endif

    private func setQuality(wifi: StreamingQuality, cellular: StreamingQuality) {
        UserDefaults.standard.set(wifi.rawValue, forKey: StreamingQuality.wifiKey)
        UserDefaults.standard.set(cellular.rawValue, forKey: StreamingQuality.cellularKey)
        state.player?.setStreamingQuality(wifi: wifi, cellular: cellular)
    }

    // Stored as the libraries to show, with EMPTY meaning all of them, so a
    // library added on the server later shows up without visiting Settings.
    // The switches present the same thing as on/off per library.
    private func isOn(_ id: String) -> Bool { selected.isEmpty || selected.contains(id) }

    private var enabledCount: Int { selected.isEmpty ? libraries.count : selected.count }

    private func setEnabled(_ id: String, _ on: Bool) {
        var enabled = selected.isEmpty ? Set(libraries.map(\.id)) : selected
        if on { enabled.insert(id) } else { enabled.remove(id) }
        guard !enabled.isEmpty else { return }
        selected = enabled.count == libraries.count ? [] : enabled
        let ids = Array(selected)
        Task { await state.setLibraries(ids) }
    }
}

#if os(iOS)
/// The iPhone's first-run setup: the desktop and Mac wizard's playback steps
/// (quality and crossfade) on one page, with cellular quality and
/// normalization beside them. The phone has no theme or library step to
/// offer. Shown once per wizard revision that brought a step it has, keyed as
/// on the other apps (`cascade.wizardSeenRevision`). Every control seeds from
/// the live value and writes as Settings does, so Done and swiping it away
/// are the same, and skipping changes nothing.
private struct PhoneSetupSheet: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .task(id: state.isSignedIn) {
                guard state.isSignedIn else { return }
                let defaults = UserDefaults.standard
                let seen = SetupWizard.seenRevision(wizardSeenRevision: defaults.object(forKey: "cascade.wizardSeenRevision"),
                                                    firstRunWizardSeen: defaults.object(forKey: "cascade.firstRunWizardSeen"))
                let steps = SetupWizard.steps(seen: seen, needsLibraryStep: false)
                if steps.contains(.crossfade) || steps.contains(.quality), state.player != nil {
                    presented = true
                } else if seen < SetupWizard.revision {
                    // Only steps the phone does not have are new: nothing to ask.
                    markSeen()
                }
            }
            .sheet(isPresented: $presented, onDismiss: markSeen) {
                if let player = state.player { PhoneSetupView(player: player) }
            }
    }

    private func markSeen() {
        UserDefaults.standard.set(SetupWizard.revision, forKey: "cascade.wizardSeenRevision")
        UserDefaults.standard.set(true, forKey: "cascade.firstRunWizardSeen")
    }
}

private struct PhoneSetupView: View {
    let player: PlaybackService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Streaming Quality", selection: Binding(
                        get: { player.streamingQuality },
                        set: { setQuality(wifi: $0, cellular: player.cellularQuality) })) {
                        ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("On Cellular", selection: Binding(
                        get: { player.cellularQuality },
                        set: { setQuality(wifi: player.streamingQuality, cellular: $0) })) {
                        ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Below the original, the server converts to AAC at that rate. A lower cellular setting saves data away from Wi-Fi.")
                }
                Section {
                    Picker("Crossfade", selection: Binding(
                        get: { Int(player.crossfadeSeconds) },
                        set: {
                            player.crossfadeSeconds = Double($0)
                            UserDefaults.standard.set($0, forKey: "cascade.crossfadeSeconds")
                        })) {
                        Text("Off").tag(0)
                        ForEach(Array(Crossfade.range), id: \.self) { Text("\($0) s").tag($0) }
                    }
                    Picker("Volume Normalization", selection: Binding(
                        get: { player.normalization },
                        set: {
                            player.normalization = $0
                            UserDefaults.standard.set($0.rawValue, forKey: "cascade.normalization")
                        })) {
                        Text("Off").tag(Normalization.Mode.off)
                        Text("By Track").tag(Normalization.Mode.track)
                        Text("By Album").tag(Normalization.Mode.album)
                    }
                } header: {
                    Text("Between Songs")
                } footer: {
                    Text("Crossfade blends the end of each song into the next; off keeps albums gapless. Normalization evens out loudness using the server's scan.")
                }
                Section {
                    Text("All of this is in Settings later, with the equalizer and lyrics options.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Set Up Cascade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func setQuality(wifi: StreamingQuality, cellular: StreamingQuality) {
        UserDefaults.standard.set(wifi.rawValue, forKey: StreamingQuality.wifiKey)
        UserDefaults.standard.set(cellular.rawValue, forKey: StreamingQuality.cellularKey)
        player.setStreamingQuality(wifi: wifi, cellular: cellular)
    }
}

extension View {
    func phoneSetup() -> some View { modifier(PhoneSetupSheet()) }
}
#endif
