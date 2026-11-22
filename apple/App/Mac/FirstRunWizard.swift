import SwiftUI
import CascadeKit

/// The first-run wizard: libraries, crossfade, quality, theme, translation,
/// and telemetry once it is switched on.
/// renderer.js's setup wizard, keyed off `cascade.wizardSeenRevision` with
/// per-step revisions (CascadeKit's SetupWizard decides which steps show).
///
/// Every step seeds from the live value and writes through the same
/// SettingsActions Settings uses, so there is nowhere for the two to drift
/// apart, and skipping a step changes nothing. Do not add a step that writes a
/// default on entry: an update re-shows the wizard to existing users.
@MainActor
@Observable
final class FirstRunModel {
    enum Mode { case wizard, videoIntro }

    var mode: Mode = .wizard
    var steps: [SetupWizard.Step] = []
    var index = 0
    var isFirstRun = true
    var presented = false
    private var checked = false

    var step: SetupWizard.Step { steps[min(index, steps.count - 1)] }
    var isLast: Bool { index >= steps.count - 1 }

    /// Decides, once per sign-in, whether to show anything. A music-only
    /// server has nothing to introduce, and the video intro's flag is burned
    /// quietly when there is nothing left to choose.
    func checkIfNeeded(state: AppState) async {
        guard !checked, state.isSignedIn, let client = state.client else { return }
        checked = true
        let defaults = UserDefaults.standard
        let views = (try? await client.views()) ?? []
        let seen = SetupWizard.seenRevision(wizardSeenRevision: defaults.object(forKey: "cascade.wizardSeenRevision"),
                                            firstRunWizardSeen: defaults.object(forKey: "cascade.firstRunWizardSeen"))
        #if DEBUG
        let forced = defaults.bool(forKey: "cascade.showWizard")
        #else
        let forced = false
        #endif
        let steps = SetupWizard.steps(seen: forced ? 0 : seen, needsLibraryStep: SetupWizard.needsLibraryStep(collectionTypes: views.map(\.collectionType)))
        if !steps.isEmpty {
            // The wizard's library step covers what the video intro would, so
            // showing both would be two library pickers in a row.
            defaults.set(true, forKey: "cascade.videoIntroSeen")
            self.steps = steps
            isFirstRun = (forced ? 0 : seen) == 0
            mode = .wizard
            index = 0
            presented = true
            return
        }
        guard !defaults.bool(forKey: "cascade.videoIntroSeen") else { return }
        let movies = views.filter { $0.collectionType == "movies" }.count
        let shows = views.filter { $0.collectionType == "tvshows" }.count
        let needed = SetupWizard.videoIntroNeeded(movieLibraries: movies, showLibraries: shows,
                                                  movieChoice: defaults.stringArray(forKey: "cascade.movieLibraryIds") ?? [],
                                                  showChoice: defaults.stringArray(forKey: "cascade.showLibraryIds") ?? [])
        guard needed else { defaults.set(true, forKey: "cascade.videoIntroSeen"); return }
        self.steps = [.libraries]
        mode = .videoIntro
        index = 0
        presented = true
    }

    func finish() {
        let defaults = UserDefaults.standard
        switch mode {
        case .wizard:
            defaults.set(SetupWizard.revision, forKey: "cascade.wizardSeenRevision")
            // Kept in step so a downgrade to a build that only knows the
            // boolean does not greet an existing user with the wizard again.
            defaults.set(true, forKey: "cascade.firstRunWizardSeen")
        case .videoIntro:
            defaults.set(true, forKey: "cascade.videoIntroSeen")
        }
        presented = false
    }

    func next() { if isLast { finish() } else { index += 1 } }
}

private struct FirstRunSheet: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var model = FirstRunModel()

    func body(content: Content) -> some View {
        content
            .task(id: state.isSignedIn) {
                if !state.isSignedIn { model.presented = false }
                await model.checkIfNeeded(state: state)
            }
            .sheet(isPresented: Binding(get: { model.presented }, set: { if !$0 && model.presented { model.finish() } })) {
                FirstRunWizardView(model: model).environment(state)
            }
    }
}

extension View {
    func firstRunWizard() -> some View { modifier(FirstRunSheet()) }
}

struct FirstRunWizardView: View {
    @Environment(AppState.self) private var state
    let model: FirstRunModel

    /// The caps line over the title, as Flutter's: where you are in it.
    private var caps: String {
        let lead = model.mode == .videoIntro ? "Movies and TV" : model.isFirstRun ? "Welcome to Cascade" : "New since your last update"
        return model.steps.count > 1 ? "\(lead) \u{00B7} \(model.index + 1) of \(model.steps.count)" : lead
    }

    /// Each step's title and voice line (Flutter's _steps).
    private var heading: (title: String, voice: String) {
        if model.mode == .videoIntro {
            return ("Your libraries", "This server has more than one movie or TV library. Pick the ones Cascade should show.")
        }
        switch model.step {
        case .libraries: return ("Your libraries", "Pick what Cascade shows. You can change this in Settings > Library.")
        case .crossfade: return ("Crossfade", "Fade each song into the next, or play them back to back.")
        case .quality: return ("Streaming quality", "Above this, the server converts files down. Original plays them as they are.")
        case .theme: return ("Theme", "Dark or light, and whether the album art picks the accent.")
        case .translation: return ("Lyrics translation", "Lyrics in other languages, translated on this Mac.")
        case .telemetry: return ("Usage counts", "Whether Cascade tells us, anonymously, that it is being used.")
        }
    }

    /// Personality v1, as Flutter's first-run dialog: the caps line, the step's title and voice
    /// line, its settings as the settings cards, then Back, Skip and Next on the panel.
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(caps).cx(.caps).foregroundStyle(Cx.text3)
                Text(heading.title).cx(.title).foregroundStyle(Cx.text).padding(.top, 8)
                Text(heading.voice).cx(.voice).foregroundStyle(Cx.text2).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 24).padding(.bottom, 4)
            stepView
                .formStyle(CxFormStyle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(model.step)
            HStack(spacing: 8) {
                if model.index > 0 {
                    Button("Back") { model.index -= 1 }.buttonStyle(.plain).foregroundStyle(Cx.text2)
                }
                Spacer()
                // Skippable at any point, not just from the last step: what
                // an earlier step already changed went through its real setter
                // and stays changed; a step never reached keeps today's value.
                PillButton("Skip", symbol: "forward.end") { model.finish() }
                PillButton(model.isLast ? (model.isFirstRun ? "Start listening" : "Done") : "Next",
                           symbol: model.isLast ? "checkmark" : "arrow.right", primary: true) { model.next() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 520, height: 540)
        .background(Cx.surface)
        .tint(Cx.accent)
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .libraries: LibrariesStep()
        case .crossfade: CrossfadeStep()
        case .quality: QualityStep()
        case .theme: ThemeStep()
        case .translation: TranslationStep()
        case .telemetry: Form { TelemetrySection() }
        }
    }
}

private struct LibrariesStep: View {
    var body: some View {
        Form { LibrarySettingsSection() }
    }
}

private struct CrossfadeStep: View {
    @Environment(AppState.self) private var state
    @State private var seconds = 0
    @State private var length = 6

    var body: some View {
        Form {
            Section {
                Toggle("Crossfade between songs", isOn: Binding(get: { seconds > 0 }, set: { on in
                    seconds = on ? length : 0
                    SettingsActions.setCrossfade(seconds: seconds, state: state)
                }))
                if seconds > 0 {
                    LabeledContent("Length") {
                        Stepper("\(length) s", value: Binding(get: { length }, set: {
                            length = min(Crossfade.range.upperBound, max(Crossfade.range.lowerBound, $0))
                            seconds = length
                            SettingsActions.setCrossfade(seconds: length, state: state)
                        }), in: Crossfade.range)
                    }
                }
            } footer: {
                Text("Blends the end of each song into the next. Off keeps albums gapless.")
            }
        }
        .onAppear {
            // Seeded from the live value, never from a default.
            seconds = Int(state.player?.crossfadeSeconds ?? Double(UserDefaults.standard.integer(forKey: "cascade.crossfadeSeconds")))
            if seconds > 0 { length = seconds }
        }
    }
}

private struct QualityStep: View {
    @Environment(AppState.self) private var state
    @State private var quality = StreamingQuality.original

    var body: some View {
        Form {
            Section {
                Picker("Streaming quality", selection: Binding(get: { quality }, set: {
                    quality = $0
                    SettingsActions.setQuality($0, state: state)
                })) {
                    ForEach(StreamingQuality.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Below the original, the server converts to AAC at that rate. Applies from the next track.")
            }
        }
        .onAppear { quality = state.player?.streamingQuality ?? StreamingQuality(stored: UserDefaults.standard.object(forKey: StreamingQuality.wifiKey)) }
    }
}

private struct ThemeStep: View {
    @State private var mode = "dark"
    @State private var albumArt = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { mode }, set: {
                    mode = $0
                    SettingsActions.setTheme(mode: $0)
                })) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .pickerStyle(.segmented)
                Toggle("Use the album art's color as the accent", isOn: Binding(get: { albumArt }, set: {
                    albumArt = $0
                    SettingsActions.setTheme(albumArt: $0)
                }))
            } footer: {
                Text("The Theme button in the toolbar has gradients, fonts and the lyrics look.")
            }
        }
        .onAppear { let t = SettingsActions.theme(); mode = t.mode; albumArt = t.albumArt }
    }
}

private struct TranslationStep: View {
    @State private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Translate lyrics", isOn: Binding(get: { enabled }, set: {
                    enabled = $0
                    SettingsActions.setLyricsTranslation($0)
                }))
            } footer: {
                Text("Adds a Translate button to lyrics in other languages. Translation happens on this Mac with the languages macOS has installed (System Settings, General, Language & Region, Translation Languages). Nothing about your songs is sent anywhere.")
            }
        }
        .onAppear { enabled = SettingsActions.lyricsTranslationEnabled }
    }
}
