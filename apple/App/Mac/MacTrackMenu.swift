import SwiftUI
import AppKit
import CascadeKit

// The Mac's track menu, item for item from the desktop's #track-ctx-menu and
// the now-playing menu (renderer.js). One view for a single track and for a
// selection: items that make sense for several act on all of them, the rest
// hide until exactly one is chosen.

/// What the menus' sheets and dialogs show, held once per host (a table, or a
/// row) rather than per menu, since a menu cannot present anything itself.
@MainActor @Observable
final class TrackActionState {
    var info: JfItem?
    var playlistTracks: [JfItem] = []
    var addingToPlaylist = false
    var deleting: [JfItem] = []
    var error: String?
}

extension EnvironmentValues {
    /// Set by `trackActionHost()`. Nil outside a host, where the sheet-based
    /// entries (Media Info, Delete, a multi-song Add to Playlist) hide.
    @Entry var trackActions: TrackActionState? = nil
}

extension View {
    /// Presents what the track menus below it ask for. Put it on a container
    /// (a table) or let `trackContextMenu` put it on a row.
    func trackActionHost() -> some View { modifier(TrackActionHost()) }
}

private struct TrackActionHost: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var actions = TrackActionState()

    func body(content: Content) -> some View {
        @Bindable var actions = actions
        content
            .environment(\.trackActions, actions)
            .sheet(isPresented: $actions.addingToPlaylist) {
                AddToPlaylistSheet(tracks: actions.playlistTracks).environment(state)
            }
            .sheet(item: $actions.info) { item in
                MediaInfoSheet(item: item).environment(state)
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !actions.deleting.isEmpty },
                                                                  set: { if !$0 { actions.deleting = [] } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let doomed = actions.deleting
                    actions.deleting = []
                    Task { await delete(doomed) }
                }
            } message: {
                Text("This removes the file from your server and cannot be undone.")
            }
            .writeErrorAlert($actions.error)
    }

    private var deleteTitle: String {
        actions.deleting.count == 1 ? "Delete \u{201C}\(actions.deleting[0].name ?? "this item")\u{201D}?"
            : "Delete \(actions.deleting.count) items?"
    }

    /// Re-checks the right (a dimmed item can still be triggered), deletes one
    /// at a time so a refusal names what was kept, then takes what went out of
    /// the queue and refreshes every list.
    private func delete(_ items: [JfItem]) async {
        guard state.canDelete, let client = state.client else { return }
        var gone = Set<String>()
        for item in items {
            do { try await client.deleteItem(item.id); gone.insert(item.id) }
            catch { actions.error = "Could not delete \u{201C}\(item.name ?? "item")\u{201D}: \(error.localizedDescription)"; break }
        }
        if let player = state.player, !gone.isEmpty {
            if let playing = player.item, gone.contains(playing.id) { await player.next() }
            let doomed = IndexSet(player.queueIds.enumerated().filter { gone.contains($0.element) }.map(\.offset))
            if !doomed.isEmpty { player.removeQueueItems(at: doomed) }
        }
        if !gone.isEmpty { state.libraryMutated() }
    }
}

/// The desktop's media info modal: fourteen rows from one fetch.
struct MediaInfoSheet: View {
    let item: JfItem
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(label: String, value: String)] = []
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Media Info").font(.headline)
            if failed {
                Text("Could not load").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(rows, id: \.label) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 340)
        .task {
            guard let client = state.client else { return }
            do { rows = MediaInfo.rows(try await client.mediaDetail(itemId: item.id)) } catch { failed = true }
        }
    }
}

/// Playlist page context: Remove from Playlist appears and calls this.
struct PlaylistMenuContext {
    var remove: ([JfItem]) -> Void
}

struct MacTracksMenu: View {
    let tracks: [JfItem]
    var nowPlaying = false
    var playlist: PlaylistMenuContext?
    /// Overrides of the snapshot's flags, nil until toggled; shared with the
    /// caller so its own heart agrees with this menu.
    var favorite: Binding<Bool?>?
    var played: Binding<Bool?>?
    var addingToPlaylist: Binding<Bool>?

    @Environment(AppState.self) private var state
    @Environment(\.trackActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.openItem) private var openItem
    @Environment(\.showLibraryItem) private var showLibraryItem

    private var single: JfItem? { tracks.count == 1 ? tracks[0] : nil }
    private var isFavorite: Bool { favorite?.wrappedValue ?? tracks.first?.userData?.isFavorite ?? false }
    private var isPlayed: Bool { played?.wrappedValue ?? tracks.first?.userData?.played ?? false }
    private var canNavigate: Bool { showLibraryItem != nil || openItem != nil }

    var body: some View {
        if tracks.isEmpty {
            EmptyView()
        } else {
            Section {
                Button("Play Now", systemImage: "play") { Task { await state.player?.play(tracks) } }
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    Task { await state.player?.playNext(tracks) }
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    Task { await state.player?.addToQueue(tracks) }
                }
                if let device = state.controlledDevice {
                    Button("Play on \(device.name)", systemImage: "hifispeaker") {
                        run { try await $0.play(tracks.map(\.id), on: device.id) }
                    }
                }
                if let single {
                    // One count everywhere (50), where the desktop used 25 from the More menu.
                    Button("Instant Mix", systemImage: "wand.and.stars") {
                        Task { await state.player?.playInstantMix(from: single.id) }
                    }
                }
            }
            Section {
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") {
                    let target = !isFavorite
                    run { client in for t in tracks { try await client.setFavorite(target, itemId: t.id) } }
                        then: { favorite?.wrappedValue = target }
                }
                Button(isPlayed ? "Mark as Unplayed" : "Mark as Played", systemImage: isPlayed ? "circle" : "checkmark.circle") {
                    let target = !isPlayed
                    run { client in for t in tracks { try await client.setPlayed(target, itemId: t.id) } }
                        then: { played?.wrappedValue = target }
                }
                Button("Add to Playlist\u{2026}", systemImage: "text.badge.plus") {
                    if let actions {
                        actions.playlistTracks = tracks
                        actions.addingToPlaylist = true
                    } else {
                        addingToPlaylist?.wrappedValue = true
                    }
                }
            }
            if let single {
                singleItems(single)
            }
            if let playlist {
                Section {
                    Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { playlist.remove(tracks) }
                }
            }
            Section {
                gated(tracks.count > 1 ? "Delete \(tracks.count) Items" : "Delete Media", "trash", allowed: state.canDelete,
                      note: "Needs delete permission", role: .destructive) {
                    guard state.canDelete else { return }
                    actions?.deleting = tracks
                }
                .disabled(actions == nil && state.canDelete)
            }
            if nowPlaying {
                Section {
                    Button("Stop", systemImage: "stop.fill") { Task { await state.player?.stop() } }
                    // The desktop's Clear left the song playing and the screen
                    // stale; stopping is what clearing the queue has to mean.
                    Button("Clear Queue", systemImage: "xmark.bin") { Task { await state.player?.stop() } }
                }
            }
        }
    }

    @ViewBuilder
    private func singleItems(_ track: JfItem) -> some View {
        Section {
            if actions != nil {
                Button("Media Info\u{2026}", systemImage: "info.circle") { actions?.info = track }
            }
            Button("Download\u{2026}", systemImage: "arrow.down.circle") { download(track) }
            Button("Copy Stream URL", systemImage: "link") {
                guard let config = state.config, let url = copyableStreamURL(config: config, item: track) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if canNavigate {
            Section {
                if let albumId = track.albumId {
                    Button("View Album", systemImage: "square.stack") { go(to: albumId) }
                }
                if let artist = track.albumArtists?.first ?? track.artistItems?.first {
                    Button("View Artist", systemImage: "music.mic") { go(to: artist.id) }
                }
            }
        }
        Section {
            gated("Refresh Metadata", "arrow.clockwise", allowed: state.isAdmin, note: "Admin only") {
                guard state.isAdmin else { return }
                run { try await $0.refreshMetadata(itemId: track.id) }
            }
            gated("Edit Metadata\u{2026}", "pencil", allowed: state.isAdmin, note: "Admin only") {
                guard state.isAdmin else { return }
                openWindow(id: "metadata-editor", value: track.id)
            }
            gated("Edit Images\u{2026}", "photo", allowed: state.isAdmin, note: "Admin only") {
                guard state.isAdmin, let base = state.config?.url,
                      let url = URL(string: "\(base)/web/index.html#/details?id=\(track.id)") else { return }
                openURL(url)
            }
            Button("Edit Lyrics\u{2026}", systemImage: "text.quote") { openWindow(id: "lyrics-editor", value: track.id) }
        }
    }

    /// A gated item stays visible, dimmed, with the reason in its title.
    private func gated(_ title: String, _ symbol: String, allowed: Bool, note: String,
                       role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(allowed ? title : "\(title) (\(note))", systemImage: symbol, role: role, action: action)
            .disabled(!allowed)
    }

    private func run(_ work: @escaping @Sendable (JellyfinClient) async throws -> Void, then: (() -> Void)? = nil) {
        guard let client = state.client else { return }
        let sink = actions
        Task { @MainActor in
            do { try await work(client); then?() }
            catch { sink?.error = error.localizedDescription }
        }
    }

    private func go(to id: String) {
        guard let client = state.client else { return }
        let (show, open) = (showLibraryItem, openItem)
        Task { @MainActor in
            guard let item = try? await client.item(id: id) else { return }
            state.nowPlayingOpen = false
            if let show { show(item) } else { open?(item) }
        }
    }

    /// NSSavePanel, then the file from /Items/{id}/Download.
    private func download(_ track: JfItem) {
        guard let client = state.client else { return }
        let sink = actions
        Task { @MainActor in
            let ext = (try? await client.mediaDetail(itemId: track.id))?.mediaSources?.first?.container
            let panel = NSSavePanel()
            panel.nameFieldStringValue = [track.name ?? "track", ext].compactMap { $0 }.joined(separator: ".")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try await client.downloadItem(itemId: track.id, to: url) }
            catch { sink?.error = "Could not download: \(error.localizedDescription)" }
        }
    }
}
