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
    /// Description and picture, written only when changed (the desktop's
    /// details editor). The overview as loaded, to tell.
    @State private var propsOverview = ""
    @State private var loadedOverview = ""
    @State private var newImage: Data?
    @State private var removingImage = false
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
            if tracks.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true, skeleton: .rows,
                               emptyTitle: "No songs yet", emptyMessage: isReal ? "Add some from any song\u{2019}s menu." : "Nothing matches the rules yet.")
                    .frame(maxHeight: .infinity)
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

    /// Personality v1, as the Penpot "Mac / Playlist" board and Flutter's PlaylistPage: the big
    /// header over the cover's wash, its editing buttons beside Play and Shuffle.
    private var header: some View {
        CxDetailHeader(label: isReal ? "Playlist" : "Smart playlist", title: name,
                       artId: playlistItem?.id ?? tracks.first?.albumId, meta: meta) {
            Group {
                PillButton("Play", symbol: "play.fill", primary: true) { play(shuffled: false) }
                PillButton("Shuffle", symbol: "shuffle") { play(shuffled: true) }
                if let playlistItem { CxLikeButton(item: playlistItem) }
                CxIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await load() } }
                if isReal {
                    CxIconButton(symbol: "pencil", help: "Name, picture, description and public") { openProps() }
                    CxIconButton(symbol: "trash", help: state.canDelete ? "Delete playlist" : "Needs delete permission") {
                        confirmingDelete = true
                    }
                    .disabled(!state.canDelete)
                    PillButton(editing ? "Done" : "Edit", symbol: editing ? "checkmark" : "arrow.up.arrow.down",
                               primary: editing) { toggleEditing() }
                } else if userSmart != nil {
                    CxIconButton(symbol: "trash", help: "Delete smart playlist") { confirmingDelete = true }
                    PillButton("Edit Rules", symbol: "slider.horizontal.3") { editingRules = true }
                    PillButton("Save as a Playlist", symbol: "plus") { savedName = name; savingAs = true }
                }
            }
            .disabled(tracks.isEmpty && !isLoading)
        }
    }

    /// "38 songs · 2h 41m".
    private var meta: String {
        guard !tracks.isEmpty else { return isLoading ? "" : "No songs" }
        let total = tracks.reduce(0.0) { $0 + ($1.runTimeTicks.map(seconds(fromTicks:)) ?? 0) }
        return "\(cxCount(tracks.count, "song")) \u{00B7} \(QueueMeta.formatSpan(total))"
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
        .background(Cx.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 30).padding(.bottom, 8)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(tracks.enumerated()), id: \.element.entryId) { index, track in
                row(track, index: index)
                    .listRowSeparator(.hidden)
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
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 24)
    }

    private func row(_ track: JfItem, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").cx(.small).foregroundStyle(.tertiary).monospacedDigit().frame(width: 28, alignment: .trailing)
            PlayingIndicator(itemId: track.id)
            ArtworkView(itemId: track.albumId ?? track.id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name ?? "").cx(.row).lineLimit(1).explicitMark(track.id)
                Text(track.albumArtist ?? track.artists?.first ?? "").cx(.small).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Text(track.album ?? "").cx(.small).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
            if extraTitle != nil {
                Text(extra(track)).cx(.small).foregroundStyle(.tertiary).monospacedDigit().frame(width: 100, alignment: .trailing)
                    // The full explanation: Jellyfin has no per-playlist add date.
                    .help(isReal ? "When this song was added to the server library, not to this playlist" : "")
            }
            Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "").cx(.small).monospacedDigit()
                .foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .desktopTrackRow(track.id)
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

    /// Who may set the picture and description: the plugin lets the owner,
    /// Jellyfin alone only an admin.
    private var detailsRoute: PlaylistDetails.Route? {
        PlaylistDetails.route(capabilities: state.cascadePluginInfo.capabilities,
                              pluginPresent: state.cascadePluginApi != nil, isAdmin: state.isAdmin)
    }

    private func openProps() {
        propsName = name
        newImage = nil
        removingImage = false
        propsOverview = ""
        loadedOverview = ""
        showingProps = true
        guard let playlist = playlistItem, let client = state.client else { return }
        Task {
            let overview = (try? await client.playlistOverview(playlist.id)) ?? ""
            loadedOverview = overview
            if propsOverview.isEmpty { propsOverview = overview }
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return writeError = "Could not read that file." }
        guard data.count <= PlaylistDetails.maxImageBytes else { return writeError = PlaylistDetails.ImageError.tooLarge.description }
        guard PlaylistDetails.imageType(data) != nil else { return writeError = PlaylistDetails.ImageError.notAnImage.description }
        newImage = data
        removingImage = false
    }

    private var propsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Playlist").scaledFont(.headline)
            TextField("Name", text: $propsName)
            Toggle("Public", isOn: $isPublic)
            if detailsRoute != nil, let playlist = playlistItem {
                HStack(spacing: 12) {
                    Group {
                        if let newImage, let image = PlatformImage(data: newImage) {
                            Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else if removingImage {
                            Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                        } else {
                            ArtworkView(itemId: playlist.id, size: 64)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose Picture\u{2026}", action: choosePicture)
                        Button("Remove Picture") { newImage = nil; removingImage = true }
                            .disabled(removingImage)
                    }
                }
                Text("Description").scaledFont(.caption).foregroundStyle(.secondary)
                TextEditor(text: $propsOverview)
                    .scaledFont(.body)
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .onChange(of: propsOverview) { _, text in
                        if text.count > PlaylistDetails.overviewMax { propsOverview = String(text.prefix(PlaylistDetails.overviewMax)) }
                    }
            } else {
                Text("A picture and description need the Cascade Server plugin, or an admin account.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { showingProps = false }
                Button("Save") { Task { await saveProps() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(propsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Each part is written only if it changed; anything that fails is listed,
    /// and the sheet stays open so Save tries just those again.
    private func saveProps() async {
        let trimmed = propsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlist = playlistItem, !trimmed.isEmpty, let client = state.client else { return }
        var failed: [String] = []
        do {
            try await client.updatePlaylist(playlist.id, name: trimmed, isPublic: isPublic)
            name = trimmed
            writtenName = trimmed
        } catch {
            failed.append("Name and public: \(error.localizedDescription)")
        }
        if let route = detailsRoute {
            let overview = propsOverview.trimmingCharacters(in: .whitespacesAndNewlines)
            if overview != loadedOverview.trimmingCharacters(in: .whitespacesAndNewlines) {
                do {
                    try await client.setPlaylistOverview(playlist.id, overview, route: route)
                    loadedOverview = overview
                } catch {
                    failed.append("Description: \(error.localizedDescription)")
                }
            }
            if newImage != nil || removingImage {
                do {
                    if let newImage { try await client.setPlaylistImage(playlist.id, newImage, route: route) }
                    else { try await client.removePlaylistImage(playlist.id, route: route) }
                    ArtworkCache.bust(playlist.id)
                    newImage = nil
                    removingImage = false
                } catch {
                    failed.append("Picture: \(error)")
                }
            }
        }
        state.playlistMutated()
        if failed.isEmpty { showingProps = false } else { writeError = "Some changes did not save.\n\n" + failed.joined(separator: "\n") }
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
