import SwiftUI
import AppKit
import CascadeKit

/// The album and playlist tile menu's admin and delete entries, gated like the
/// track menu's: visible, dimmed, with the reason, and checked again by the
/// handler.
struct MacItemMenuExtras: View {
    let item: JfItem
    @Binding var deletingPlaylist: Bool
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    private var kind: MenuItemKind? {
        switch item.type {
        case "MusicAlbum": .album
        case "Playlist": .playlist
        default: nil
        }
    }

    var body: some View {
        if let kind {
            let visible = menuItems(for: kind)
            Section {
                if visible.download { Button("Download\u{2026}", systemImage: "arrow.down.circle") { downloadAlbum() } }
                if visible.refreshMeta {
                    Button(state.isAdmin ? "Refresh Metadata" : "Refresh Metadata (Admin only)", systemImage: "arrow.clockwise") {
                        guard state.isAdmin, let client = state.client else { return }
                        let id = item.id
                        Task { do { try await client.refreshMetadata(itemId: id) } catch { NSAlert(error: error).runModal() } }
                    }
                    .disabled(!state.isAdmin)
                }
                if visible.editMeta {
                    Button(state.isAdmin ? "Edit Metadata\u{2026}" : "Edit Metadata (Admin only)", systemImage: "pencil") {
                        guard state.isAdmin else { return }
                        openWindow(id: "metadata-editor", value: item.id)
                    }
                    .disabled(!state.isAdmin)
                }
                if visible.deleteItem {
                    Button(state.canDelete ? "Delete Playlist" : "Delete Playlist (Needs delete permission)",
                           systemImage: "trash", role: .destructive) {
                        guard state.canDelete else { return }
                        deletingPlaylist = true
                    }
                    .disabled(!state.canDelete)
                }
            }
        }
    }

    /// One file per track into a folder, like the desktop's per-track download.
    private func downloadAlbum() {
        guard let client = state.client else { return }
        let id = item.id
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Download Here"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            do {
                for track in try await client.tracks(inAlbum: id) {
                    let ext = (try? await client.mediaDetail(itemId: track.id))?.mediaSources?.first?.container
                    let name = [track.name ?? track.id, ext].compactMap { $0 }.joined(separator: ".")
                        .replacingOccurrences(of: "/", with: "-")
                    try await client.downloadItem(itemId: track.id, to: folder.appendingPathComponent(name))
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
