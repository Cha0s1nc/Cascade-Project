import SwiftUI
import CascadeKit

/// The user's playlists, and a button to make a new one. Editing a playlist
/// happens on its own page.
struct PlaylistsView: View {
    @Environment(AppState.self) private var state
    /// Loaded and kept by AppState (see browseList), so it survives leaving
    /// this screen and keeps filling while it is off screen.
    @State private var list: BrowseList?
    private var items: [JfItem] { list?.items ?? [] }
    private var isLoading: Bool { list?.isLoading ?? true }
    private var error: String? { list?.error }
    @AppStorage("cascade.playlists.sort") private var sortField: PlaylistSortField = .name
    @AppStorage("cascade.playlists.order") private var sortDirection: SortDirection = .ascending
    @State private var creating = false
    @State private var newName = ""
    @State private var writeError: String?
    /// Bumped after a create so the list reloads with the new playlist.
    @State private var generation = 0

    var body: some View {
        ScrollView {
            HStack {
                SortMenu(fields: [(PlaylistSortField.name, "Name"), (.added, "Date Added")],
                         field: $sortField, direction: $sortDirection)
                Spacer()
                Button {
                    newName = ""
                    creating = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
            }
            .padding(.horizontal)
            .browseHeader()
            SmartPlaylistShelf()
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: items.isEmpty)
            ItemGrid(items: items)
        }
        .navigationTitle("Playlists")
        .onChange(of: sortField) { sortDirection = sortField.defaultDirection }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        }
        .writeErrorAlert($writeError)
        .refreshable { state.dropBrowseCache(.playlists); generation += 1 }
        // Kept by AppState, and dropped by every playlist write
        // (dropBrowseCache), so a playlist renamed or deleted on its own page
        // is still current when this screen comes back.
        .task(id: BrowseKey(sort: sortField.rawValue, direction: sortDirection, generation: generation)) {
            guard let client = state.client else { return }
            let (sortBy, order) = (sortField.serverSortBy, sortDirection.serverValue)
            list = state.browseList(.playlists, BrowseKey(sort: sortField.rawValue, direction: sortDirection,
                                                          generation: generation)) { list in
                list.items = try await client.playlists(sortBy: sortBy, sortOrder: order)
            }
        }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let client = state.client else { return }
        do {
            _ = try await client.createPlaylist(name: name)
            generation += 1
        } catch {
            writeError = error.localizedDescription
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

    init(playlist: JfItem) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name ?? "Playlist")
    }

    var body: some View {
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
            LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty)
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
        .task { await load() }
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
            state.dropBrowseCache(.playlists)   // its song count changed
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
            state.dropBrowseCache(.playlists)
            name = trimmed
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func deletePlaylist() async {
        guard let client = state.client else { return }
        do {
            try await client.deletePlaylist(playlist.id)
            state.dropBrowseCache(.playlists)
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
