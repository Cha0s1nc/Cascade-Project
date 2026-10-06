import SwiftUI
import CascadeKit

/// Picks a playlist to add songs to, or makes a new one with them in it.
/// Self-contained so any screen can present it: `.sheet { AddToPlaylistSheet(tracks:) }`.
///
/// Closes only once the server has accepted the write; a refusal stays on
/// screen with the server's reason. Jellyfin 10.11 skips a song already in
/// the playlist without saying so, so adding one twice is quietly a no-op.
struct AddToPlaylistSheet: View {
    let tracks: [JfItem]

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var writeError: String?
    @State private var creating = false
    @State private var newName = ""
    @State private var isSaving = false

    init(tracks: [JfItem]) { self.tracks = tracks }
    init(track: JfItem) { self.tracks = [track] }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: playlists.isEmpty)
                ForEach(playlists) { playlist in
                    Button {
                        Task { await add(to: playlist.id) }
                    } label: {
                        HStack {
                            Text(playlist.name ?? "Playlist")
                            Spacer()
                            if let count = playlist.childCount {
                                Text("\(count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(isSaving || tracks.isEmpty)
            .navigationTitle(tracks.count == 1 ? "Add to Playlist" : "Add \(tracks.count) Songs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await create() } }
            }
            .writeErrorAlert($writeError)
            .task {
                guard let client = state.client else { return }
                do { playlists = try await client.playlists() }
                catch { self.error = error.localizedDescription }
                isLoading = false
            }
        }
    }

    private func add(to playlistId: String) async {
        // Also guarded here, not only by the disabled list.
        guard !isSaving, !tracks.isEmpty, let client = state.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.addToPlaylist(playlistId, itemIds: tracks.map(\.id))
            state.playlistMutated()   // its song count changed
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isSaving, let client = state.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.createPlaylist(name: name, itemIds: tracks.map(\.id))
            state.playlistMutated()
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
