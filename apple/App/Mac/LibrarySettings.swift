import SwiftUI
import CascadeKit

/// Music library picker with single-library mode, and the movie and TV library
/// choices, which the desktop keeps apart from the music one. Embedded by
/// Settings > Library.
struct LibrarySettingsSection: View {
    @Environment(AppState.self) private var state
    @State private var musicLibraries: [JfItem] = []
    @State private var loaded = false
    @State private var error: String?
    /// The desktop's key (`singleLibraryMode`): one music library at a time,
    /// chosen from a menu, instead of several merged into one view.
    @AppStorage("cascade.singleLibraryMode") private var singleMode = false

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    /// Stored as the libraries to show, with EMPTY meaning all of them (see
    /// SettingsView), so a library added on the server later shows up.
    private var selected: Set<String> { Set(state.config?.libraryIds ?? []) }
    private var musicOn: Set<String> { selected.isEmpty ? Set(musicLibraries.map(\.id)) : selected }

    var body: some View {
        Form {
            Section {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if loaded, musicLibraries.isEmpty {
                    Text("No music libraries found").foregroundStyle(.secondary)
                } else {
                    // Merging is meaningless with one library, so the switch is
                    // noise then; the list stays, as the only place to see which
                    // library you are on.
                    if musicLibraries.count > 1 {
                        Toggle("Single library", isOn: $singleMode)
                    }
                    if singleMode, musicLibraries.count > 1 {
                        Picker("Library", selection: Binding(
                            get: { musicOn.count == 1 ? musicOn.first : musicLibraries.first?.id },
                            set: { if let id = $0 { choose([id]) } }
                        )) {
                            ForEach(musicLibraries) { Text($0.name ?? "Unknown").tag(Optional($0.id)) }
                        }
                    } else {
                        ForEach(musicLibraries) { library in
                            Toggle(library.name ?? "Unknown", isOn: Binding(
                                get: { musicOn.contains(library.id) },
                                set: { setMusic(library.id, $0) }
                            ))
                            // The last one on stays on: with none there is nothing to browse.
                            .disabled(musicOn.contains(library.id) && musicOn.count == 1)
                        }
                    }
                }
            } header: {
                Text("Music libraries")
            } footer: {
                Text(singleMode && musicLibraries.count > 1
                     ? "Only this library is shown. Changes apply immediately."
                     : "Merged into one view. Changes apply immediately.")
            }

            videoSection("Movie libraries", libraries.movieLibraries, ids: libraries.movieIds,
                         set: { libraries.setMovieIds($0) })
            videoSection("TV libraries", libraries.showLibraries, ids: libraries.showIds,
                         set: { libraries.setShowIds($0) })
        }
        .formStyle(.grouped)
        .task(id: state.config?.userId) {
            guard let client = state.client else { return }
            await libraries.load(client: client, userId: state.config?.userId)
            // Every music library, not musicLibraries(): that one is filtered
            // to the current selection, so after picking one the others
            // vanished from the list and could never be picked again.
            do {
                musicLibraries = try await client.views().filter { $0.collectionType == "music" }
                // Single mode holds exactly one; a selection made elsewhere
                // (the phone's settings never use single mode) is cut to its first.
                if singleMode, musicOn.count > 1, let first = musicLibraries.first(where: { musicOn.contains($0.id) }) {
                    choose([first.id])
                }
            } catch {
                self.error = error.localizedDescription
            }
            loaded = true
        }
        .onChange(of: singleMode) {
            if singleMode, musicOn.count > 1, let first = musicLibraries.first(where: { musicOn.contains($0.id) }) {
                choose([first.id])
            }
        }
    }

    @ViewBuilder
    private func videoSection(_ title: String, _ libs: [JfItem], ids: [String], set: @escaping ([String]) -> Void) -> some View {
        if !libs.isEmpty {
            Section {
                ForEach(libs) { library in
                    Toggle(library.name ?? "Unknown", isOn: Binding(
                        get: { ids.contains(library.id) },
                        set: { on in
                            // Unlike music, none is a real choice: it turns that
                            // kind off (and hides its sidebar rows' content).
                            var next = ids.filter { $0 != library.id }
                            if on { next.append(library.id) }
                            set(libs.map(\.id).filter(next.contains))
                        }
                    ))
                }
            } header: {
                Text(title)
            } footer: {
                Text(ids.isEmpty ? "None chosen, so nothing from these shows." : "Each library is its own group in the poster grid.")
            }
        }
    }

    private func choose(_ ids: [String]) {
        Task { await state.setLibraries(ids.count == musicLibraries.count ? [] : ids) }
    }

    private func setMusic(_ id: String, _ on: Bool) {
        var enabled = musicOn
        if on { enabled.insert(id) } else { enabled.remove(id) }
        guard !enabled.isEmpty else { return }
        choose(Array(enabled))
    }
}
