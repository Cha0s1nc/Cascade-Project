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

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: state.config?.url ?? "")
                LabeledContent("Signed in as", value: username ?? "")
            }

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

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmingSignOut = true
                }
            }

            Section("About") {
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
            do { libraries = try await client.views().filter { $0.collectionType == "music" } }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
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
