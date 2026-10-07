import SwiftUI
import CascadeKit

/// A playlist's page on the Mac, real or smart (the desktop's playlist detail):
/// a list you can multi-select, drag to reorder, and edit in bulk. Every write
/// goes to the server first through one whole-Ids save, then `playlistMutated`
/// makes the page re-read it, so what shows is never what failed to save.
struct MacPlaylistDetail: View {
    enum Source {
        case playlist(JfItem)
        /// "favorites", "most-played" or a user smart playlist's id.
        case smart(String)
    }
    let source: Source

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var tracks: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var writeError: String?
    @State private var selection = Set<String>()
    @State private var editing = false
    @State private var isPublic = false
    @State private var canEdit = true
    @State private var showingProps = false
    @State private var propsName = ""
    /// A rename this page made, held until the server reads it back the same.
    @State private var writtenName: String?
    @State private var confirmingDelete = false
    @State private var editingRules = false
    @State private var savingAs = false
    @State private var savedName = ""

    private var playlistItem: JfItem? { if case .playlist(let p) = source { p } else { nil } }
    private var smartKind: String? { if case .smart(let k) = source { k } else { nil } }
    private var userSmart: SmartPlaylist? { smartKind.flatMap { k in state.smartPlaylists.first { $0.id == k } } }
    private var isReal: Bool { playlistItem != nil }
    private var extraTitle: String? {
        if isReal { return "Added (server)" }
        return smartKind == "most-played" ? "Plays" : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if editing && isReal { bulkBar }
            Divider()
            if tracks.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true, skeleton: .rows).frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle(name)
        .writeErrorAlert($writeError)
        .task(id: LoadKey(revision: state.playlistRevision, rules: userSmart)) { await load() }
        .sheet(isPresented: $showingProps) { propsSheet }
        .sheet(isPresented: $editingRules) {
            if let userSmart { SmartPlaylistEditor(playlist: userSmart).environment(state) }
        }
        .alert("Save as a Playlist", isPresented: $savingAs) {
            TextField("Name", text: $savedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await saveAsPlaylist() } }
        } message: {
            Text("Makes a regular playlist from the songs shown now.")
        }
        .confirmationDialog("Delete \u{201C}\(name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(isReal ? "Delete Playlist" : "Delete Smart Playlist", role: .destructive) { Task { await deleteThis() } }
        } message: {
            Text(isReal ? "The songs stay in your library." : "This only removes the rules.")
        }
    }

    private struct LoadKey: Hashable { var revision: Int; var rules: SmartPlaylist? }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            if let playlistItem { ArtworkView(itemId: playlistItem.id, size: 72) }
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.title2.bold()).lineLimit(1)
                Text(tracks.count == 1 ? "1 song" : "\(tracks.count) songs").foregroundStyle(.secondary)
                HStack {
                    Button { play(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { play(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                    if isReal {
                        Button(editing ? "Done" : "Edit") { toggleEditing() }
                        Button { propsName = name; showingProps = true } label: { Image(systemName: "pencil") }
                            .help("Rename or make public")
                        Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                            .disabled(!state.canDelete)
                            .help(state.canDelete ? "Delete playlist" : "Needs delete permission")
                    } else if userSmart != nil {
                        Button("Edit Rules") { editingRules = true }
                        Button("Save as a Playlist") { savedName = name; savingAs = true }
                        Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                    }
                }
                .disabled(tracks.isEmpty && !isLoading)
            }
            Spacer()
        }
        .padding(14)
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Toggle("Select All", isOn: Binding(
                get: { !tracks.isEmpty && selection.count == tracks.count },
                set: { selection = $0 ? Set(tracks.map(\.entryId)) : [] }))
            Text("\(selection.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Move to Top") { save(PlaylistEdit.movingToTop(tracks, selected: selection)) }
            Button("Move to Bottom") { save(PlaylistEdit.movingToBottom(tracks, selected: selection)) }
            Button("Remove", role: .destructive) { save(PlaylistEdit.removing(tracks, selected: selection)); selection = [] }
        }
        .disabled(!canEdit)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(tracks.enumerated()), id: \.element.entryId) { index, track in
                row(track, index: index)
            }
            .onMove(perform: isReal && canEdit ? { from, to in
                var order = tracks
                order.move(fromOffsets: from, toOffset: to)
                save(order, optimistic: true)
            } : nil)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = tracks.filter { ids.contains($0.entryId) }
            MacTracksMenu(tracks: chosen, playlist: isReal && canEdit
                          ? PlaylistMenuContext(remove: { save(PlaylistEdit.removing(tracks, selected: Set($0.map(\.entryId)))) })
                          : nil)
            // Explicit, as in SongsTable: a selection menu can be built
            // outside the page's environment.
            .environment(state)
        } primaryAction: { ids in
            guard let first = tracks.firstIndex(where: { ids.contains($0.entryId) }) else { return }
            RecentPlaylists.touch(playlistItem?.id ?? smartKind ?? "")
            Task { await state.player?.play(tracks, startIndex: first) }
        }
        .trackActionHost()
    }

    private func row(_ track: JfItem, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
            PlayingIndicator(itemId: track.id)
            ArtworkView(itemId: track.albumId ?? track.id, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name ?? "").lineLimit(1)
                Text(track.albumArtist ?? track.artists?.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(track.album ?? "").foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
            if extraTitle != nil {
                Text(extra(track)).foregroundStyle(.secondary).monospacedDigit().frame(width: 100, alignment: .trailing)
                    // The full explanation: Jellyfin has no per-playlist add date.
                    .help(isReal ? "When this song was added to the server library, not to this playlist" : "")
            }
            Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "").monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private func extra(_ track: JfItem) -> String {
        if isReal {
            guard let date = PlayHistory.date(track.dateCreated) else { return "\u{2014}" }
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return String(track.userData?.playCount ?? 0)
    }

    // MARK: Actions

    private func play(shuffled: Bool) {
        RecentPlaylists.touch(playlistItem?.id ?? smartKind ?? "")
        Task {
            if shuffled { await playShuffled(tracks, on: state.player) } else { await state.player?.play(tracks, startIndex: 0) }
        }
    }

    private func toggleEditing() {
        editing.toggle()
        selection = []
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            switch source {
            case .playlist(let p):
                tracks = try await client.tracks(inPlaylist: p.id)
                // Name and flags may have changed elsewhere; the item is the truth.
                if let fresh = try await client.items(ids: [p.id]).first?.name {
                    // Jellyfin can answer with the old name for a moment after
                    // a rename (seen on 10.11.11: new, old, then new again
                    // within 200 ms), so what this page just wrote stands
                    // until the server says the same.
                    if writtenName == nil || fresh == writtenName { name = fresh; writtenName = nil }
                }
                let info = try await client.playlistInfo(p.id)
                (isPublic, canEdit) = (info.isPublic, info.canEdit)
            case .smart(let kind):
                switch kind {
                case "favorites": name = "Favorites"; tracks = try await client.favoriteSongs()
                case "most-played": name = "Most Played"; tracks = try await client.mostPlayedSongs()
                default:
                    guard let userSmart else { return }
                    name = userSmart.name
                    tracks = try await client.songs(matching: userSmart)
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        selection = selection.filter { id in tracks.contains { $0.entryId == id } }
        isLoading = false
    }

    /// The one save for every reorder and removal: the whole new order in one
    /// request, then the page re-reads. A drag is shown at once (SwiftUI has
    /// drawn it) and put right again by the re-read if the server said no.
    private func save(_ order: [JfItem], optimistic: Bool = false) {
        guard let playlist = playlistItem, canEdit, let client = state.client else { return }
        if optimistic { tracks = order }
        Task {
            do {
                try await client.setPlaylistItems(playlist.id, itemIds: order.map(\.id))
            } catch {
                writeError = error.localizedDescription
            }
            state.playlistMutated()
        }
    }

    private var propsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Playlist").font(.headline)
            TextField("Name", text: $propsName)
            Toggle("Public", isOn: $isPublic)
            HStack {
                Spacer()
                Button("Cancel") { showingProps = false }
                Button("Save") { Task { await saveProps() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(propsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func saveProps() async {
        let trimmed = propsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlist = playlistItem, !trimmed.isEmpty, let client = state.client else { return }
        do {
            try await client.updatePlaylist(playlist.id, name: trimmed, isPublic: isPublic)
            name = trimmed
            writtenName = trimmed
            showingProps = false
            state.playlistMutated()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func saveAsPlaylist() async {
        let trimmed = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tracks.isEmpty, let client = state.client else { return }
        do {
            _ = try await client.createPlaylist(name: trimmed, itemIds: tracks.map(\.id))
            state.playlistMutated()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func deleteThis() async {
        if let playlist = playlistItem {
            // Re-checked: the button is dimmed, not absent.
            guard state.canDelete, let client = state.client else { return }
            do {
                try await client.deleteItem(playlist.id)
                state.playlistMutated()
                dismiss()
            } catch {
                writeError = error.localizedDescription
            }
        } else if let id = smartKind {
            state.deleteSmartPlaylist(id: id)
            dismiss()
        }
    }
}
