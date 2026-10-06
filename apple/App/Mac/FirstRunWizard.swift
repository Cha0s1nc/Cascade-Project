import SwiftUI
import CascadeKit

/// The first-run wizard: libraries, crossfade, quality, theme, translation.
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

    private var heading: String {
        switch model.mode {
        case .videoIntro: "Movies and TV"
        case .wizard: model.isFirstRun ? "Set up Cascade" : "New since your last update"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.title2.bold())
                Text(model.mode == .videoIntro
                     ? "This server has more than one movie or TV library. Pick the ones Cascade should show. All of it lives in Settings afterwards."
                     : "Your current settings are already filled in, so skipping changes nothing. All of it lives in Settings afterwards.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 24).padding(.bottom, 12)
            Divider()
            stepView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(model.step)
            Divider()
            HStack {
                if model.steps.count > 1 {
                    Text("Step \(model.index + 1) of \(model.steps.count)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Skippable at any point, not just from the last step: what
                // an earlier step already changed went through its real setter
                // and stays changed; a step never reached keeps today's value.
                Button("Skip") { model.finish() }
                Button(model.isLast ? "Done" : "Next") { model.next() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 520, height: 520)
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder private var stepView: some View {
        switch model.step {
        case .libraries: LibrariesStep()
        case .crossfade: CrossfadeStep()
        case .quality: QualityStep()
        case .theme: ThemeStep()
        case .translation: TranslationStep()
        }
    }
}

private struct LibrariesStep: View {
    var body: some View {
        Form { LibrarySettingsSection() }.formStyle(.grouped)
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
        .formStyle(.grouped)
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
        .formStyle(.grouped)
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
        .formStyle(.grouped)
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
        .formStyle(.grouped)
        .onAppear { enabled = SettingsActions.lyricsTranslationEnabled }
    }
}
