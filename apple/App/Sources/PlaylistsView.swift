import SwiftUI
import CascadeKit
#if os(iOS)
import PhotosUI
#endif

/// The user's playlists, and a button to make a new one. Editing a playlist
/// happens on its own page.
struct PlaylistsView: View {
    @Environment(AppState.self) private var state
    /// Loaded and kept by AppState (see browseList), so it survives leaving
    /// this screen and keeps filling while it is off screen.
    @State private var list: BrowseList?
    private var items: [JfItem] { arrangedPlaylists(list?.items ?? [], by: prefs) }
    private var isLoading: Bool { list?.isLoading ?? true }
    private var error: String? { list?.error }
    // The desktop's key and shape (cascade.playlistsPrefs): field name, added
    // or count, direction, and the favorites filter. Arranged on the loaded
    // list, which is whole.
    @AppStorage("cascade.playlistsPrefs") private var prefs = LibraryPrefs()
    private var sortField: PlaylistPrefsField { prefs.sortField(default: .name) }
    @State private var creating = false
    @State private var writeError: String?
    /// Bumped after a create so the list reloads with the new playlist.
    @State private var generation = 0

    var body: some View {
        ScrollView {
            HStack {
                SortMenu(fields: [(PlaylistPrefsField.name, "Name"), (.added, "Date Added"), (.count, "Song Count")],
                         field: Binding(get: { sortField }, set: { prefs.field = $0.rawValue }),
                         direction: Binding(get: { prefs.direction }, set: { prefs.direction = $0 }),
                         favoritesOnly: Binding(get: { prefs.filter.favoritesOnly }, set: { prefs.filter.favoritesOnly = $0 }))
                Spacer()
                // One button for both kinds, as on the desktop: the sheet asks
                // Normal or Smart. The smart shelf's own New tile is gone.
                Button {
                    creating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                #if os(macOS)
                Button { state.playlistMutated(); generation += 1 } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                #endif
            }
            .padding(.horizontal)
            .browseHeader()
            SmartPlaylistShelf()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty, skeleton: .grid)
            ItemGrid(items: items)
        }
        .navigationTitle("Playlists")
        .onChange(of: prefs.field) { prefs.direction = sortField.defaultDirection }
        .sheet(isPresented: $creating) {
            NewPlaylistSheet().environment(state)
        }
        .writeErrorAlert($writeError)
        .refreshable { state.playlistMutated(); generation += 1 }
        // Kept by AppState, and dropped by every playlist write
        // (playlistMutated), so a playlist renamed or deleted on its own page
        // is still current when this screen comes back.
        .task(id: BrowseKey(sort: "all", direction: .ascending, generation: generation + state.playlistRevision * 1000)) {
            guard let client = state.client else { return }
            list = state.browseList(.playlists, BrowseKey(sort: "all", direction: .ascending,
                                                          generation: generation + state.playlistRevision * 1000)) { list in
                list.items = try await client.playlists()
            }
        }
    }

}

/// New Playlist: a normal playlist on the server, or a smart one built from
/// rules (kept on this device, as the desktop keeps them), picked at the top.
struct NewPlaylistSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case normal = "Normal", smart = "Smart"
        var id: Self { self }
    }

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var kind = Kind.normal
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            switch kind {
            case .smart:
                // Its own Cancel and Save; Save dismisses this whole sheet.
                SmartPlaylistEditor(playlist: SmartPlaylist(name: name))
            case .normal:
                normal
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: kind == .smart ? 520 : 220)
        #endif
    }

    private var normal: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .onSubmit { Task { await create() } }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("New Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving, let client = state.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.createPlaylist(name: trimmed)
            state.playlistMutated()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A playlist's songs, with play, shuffle, rename and delete, and editing of
/// its contents: on iOS swipe to remove and Edit to drag into a new order; on
/// tvOS, where neither exists, press and hold a song for Move Up, Move Down
/// and Remove.
///
/// Every edit is sent to the server first and only then shown, except a
/// drag, which SwiftUI has already drawn; a refused move or remove reloads
/// the playlist from the server so the screen never shows an order that was
/// not saved.
struct PlaylistDetailView: View {
    let playlist: JfItem

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var tracks: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var writeError: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var editingDetails = false

    init(playlist: JfItem) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name ?? "Playlist")
    }

    var body: some View {
        #if os(macOS)
        MacPlaylistDetail(source: .playlist(playlist))
        #else
        listBody
        #endif
    }

    private var listBody: some View {
        List {
            header
            ForEach(Array(tracks.enumerated()), id: \.element.entryId) { index, track in
                Button {
                    RecentPlaylists.touch(playlist.id)
                    Task { await state.player?.play(tracks, startIndex: index) }
                } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                #if os(tvOS)
                .contextMenu {
                    if index > 0 {
                        Button("Move Up", systemImage: "arrow.up") { Task { await move(index, to: index - 1) } }
                    }
                    if index < tracks.count - 1 {
                        Button("Move Down", systemImage: "arrow.down") { Task { await move(index, to: index + 1) } }
                    }
                    Button("Remove from Playlist", systemImage: "trash", role: .destructive) {
                        Task { await remove(IndexSet(integer: index)) }
                    }
                }
                #endif
            }
            #if os(iOS)
            .onDelete { offsets in Task { await remove(offsets) } }
            .onMove { from, offset in
                guard let source = from.first else { return }
                Task { await move(source, to: playlistMoveIndex(from: source, toOffset: offset)) }
            }
            #endif
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty, skeleton: .rows)
        }
        .navigationTitle(name)
        #if os(iOS)
        .toolbar {
            DownloadButton(item: playlist)
            EditButton()
        }
        #endif
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await rename() } }
        }
        .confirmationDialog("Delete \u{201C}\(name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { Task { await deletePlaylist() } }
        } message: {
            Text("The songs stay in your library.")
        }
        .writeErrorAlert($writeError)
        #if os(iOS)
        .sheet(isPresented: $editingDetails) {
            if let route = detailsRoute { PlaylistDetailsSheet(playlist: playlist, route: route) }
        }
        #endif
        .task { await load() }
    }

    /// Who may set the picture and description: the plugin lets the owner,
    /// Jellyfin alone only an admin.
    private var detailsRoute: PlaylistDetails.Route? {
        PlaylistDetails.route(capabilities: state.cascadePluginInfo.capabilities,
                              pluginPresent: state.cascadePluginApi != nil, isAdmin: state.isAdmin)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemId: playlist.id, size: 200)
            Text(name)
                .font(.title2.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(tracks.count == 1 ? "1 song" : "\(tracks.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    RecentPlaylists.touch(playlist.id)
                    Task { await state.player?.play(tracks, startIndex: 0) }
                } label: {
                    Label("Play", systemImage: "play.fill").labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
                Button {
                    RecentPlaylists.touch(playlist.id)
                    Task { await playShuffled(tracks, on: state.player) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle").labelStyle(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
                Button {
                    newName = name
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                #if os(iOS)
                if detailsRoute != nil {
                    Button { editingDetails = true } label: {
                        Label("Picture and Description", systemImage: "photo").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                }
                #endif
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
        .browseHeader()
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            tracks = try await client.tracks(inPlaylist: playlist.id)
            error = nil
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func remove(_ offsets: IndexSet) async {
        guard let client = state.client else { return }
        let entries = offsets.map { tracks[$0].entryId }
        do {
            try await client.removeFromPlaylist(playlist.id, entryIds: entries)
            state.playlistMutated()   // its song count changed
            tracks.removeAll { entries.contains($0.entryId) }
        } catch {
            writeError = error.localizedDescription
            await load()
        }
    }

    /// `index` is the final position, which is what the server counts in.
    private func move(_ source: Int, to index: Int) async {
        guard let client = state.client, tracks.indices.contains(source),
              tracks.indices.contains(index), source != index else { return }
        let entry = tracks[source].entryId
        // Shown straight away: on iOS the drag has already put it there.
        tracks.insert(tracks.remove(at: source), at: index)
        do {
            try await client.movePlaylistEntry(playlist.id, entryId: entry, to: index)
        } catch {
            writeError = error.localizedDescription
            await load()
        }
    }

    private func rename() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name, let client = state.client else { return }
        do {
            try await client.renamePlaylist(playlist.id, to: trimmed)
            state.playlistMutated()
            name = trimmed
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func deletePlaylist() async {
        guard let client = state.client else { return }
        do {
            try await client.deletePlaylist(playlist.id)
            state.playlistMutated()
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}

#if os(iOS)
/// A playlist's picture and description (the Mac's Edit Playlist sheet has
/// the same). Photos often hands over HEIC, which the server does not take,
/// so a picked photo goes up as a JPEG, scaled to fit the size limit.
struct PlaylistDetailsSheet: View {
    let playlist: JfItem
    let route: PlaylistDetails.Route

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var picked: PhotosPickerItem?
    @State private var newImage: Data?
    @State private var removingImage = false
    @State private var overview = ""
    @State private var loadedOverview = ""
    @State private var saving = false
    @State private var writeError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Picture") {
                    HStack(spacing: 16) {
                        Group {
                            if let newImage, let image = UIImage(data: newImage) {
                                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                            } else if removingImage {
                                Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                            } else {
                                ArtworkView(itemId: playlist.id, size: 80)
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker("Choose Photo", selection: $picked, matching: .images)
                            Button("Remove Picture", role: .destructive) { newImage = nil; removingImage = true }
                                .disabled(removingImage)
                        }
                    }
                }
                Section("Description") {
                    TextField("Description", text: $overview, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: overview) { _, text in
                            if text.count > PlaylistDetails.overviewMax { overview = String(text.prefix(PlaylistDetails.overviewMax)) }
                        }
                }
            }
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let jpeg = Self.jpeg(data) else { return writeError = PlaylistDetails.ImageError.notAnImage.description }
                    newImage = jpeg
                    removingImage = false
                }
            }
            .task {
                guard let client = state.client else { return }
                let text = (try? await client.playlistOverview(playlist.id)) ?? ""
                loadedOverview = text
                if overview.isEmpty { overview = text }
            }
            .writeErrorAlert($writeError)
        }
    }

    /// Any photo as a JPEG under the size limit: scaled down until it fits.
    static func jpeg(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        var side: CGFloat = 1600
        while side >= 200 {
            let scale = min(1, side / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) {
                _ in image.draw(in: CGRect(origin: .zero, size: size))
            }
            if jpeg.count <= PlaylistDetails.maxImageBytes { return jpeg }
            side /= 1.5
        }
        return nil
    }

    /// Each part is written only if it changed; anything that fails is listed
    /// and the sheet stays open, as on the Mac.
    private func save() async {
        guard let client = state.client else { return }
        saving = true
        defer { saving = false }
        var failed: [String] = []
        let text = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != loadedOverview.trimmingCharacters(in: .whitespacesAndNewlines) {
            do {
                try await client.setPlaylistOverview(playlist.id, text, route: route)
                loadedOverview = text
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
        state.playlistMutated()
        if failed.isEmpty { dismiss() } else { writeError = "Some changes did not save.\n\n" + failed.joined(separator: "\n") }
    }
}
#endif
