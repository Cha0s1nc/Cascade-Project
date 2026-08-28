import SwiftUI
import CascadeKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var libraries: [JfItem] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmingSignOut = false

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Server", value: state.config?.url ?? "")
                LabeledContent("User ID", value: state.config?.userId ?? "")
            }

            Section {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: libraries.isEmpty)
                ForEach(libraries) { library in
                    Button {
                        toggle(library.id)
                    } label: {
                        HStack {
                            Text(library.name ?? "Unknown")
                            Spacer()
                            if selected.contains(library.id) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Libraries")
            } footer: {
                Text(selected.isEmpty ? "All libraries" : "\(selected.count) selected")
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
            do { libraries = try await client.musicLibraries() }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        state.setLibraries(Array(selected))
    }
}
