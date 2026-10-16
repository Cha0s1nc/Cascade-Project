import SwiftUI
import CascadeKit

#if os(iOS) || os(macOS)
/// The download manager: storage, what is still downloading, and what is
/// downloaded. Drawn entirely from what was saved, so it works with no
/// server at all, which is the point of it. tvOS has no downloads: its
/// storage is a cache the system empties as it likes.
struct DownloadsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmingRemoveAll = false
    /// Free and total bytes on the disk, read when the screen opens.
    @State private var disk: (free: Int64, total: Int64)?
    #if os(macOS)
    private static let device = "Mac"
    #else
    private static let device = "iPhone"
    #endif

    var body: some View {
        if let offline = state.offline, offline.index.collections.isEmpty, offline.lastError == nil {
            // Centred on its own: inside the list it sat in the top corner on the Mac.
            ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                   description: Text("Download an album or playlist from its menu to play it without a connection."))
                .navigationTitle("Downloads")
        } else {
            list
        }
    }

    private func isDone(_ c: OfflineIndex.Collection, _ offline: OfflineLibrary) -> Bool {
        let p = offline.index.progress(c.id)
        return p.done == p.total
    }

    private var list: some View {
        List {
            if let offline = state.offline {
                Section {
                    LabeledContent("Downloads use", value: bytes(offline.index.totalBytes))
                    if let disk {
                        LabeledContent("Free on this \(Self.device)", value: bytes(disk.free))
                    }
                } header: {
                    Text("Storage")
                }
                if let message = offline.lastError {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                let downloading = offline.index.collections.filter { !isDone($0, offline) }
                let done = offline.index.collections.filter { isDone($0, offline) }
                if !downloading.isEmpty {
                    Section {
                        rows(downloading, offline)
                    } header: {
                        Text("Downloading")
                    } footer: {
                        if state.isOffline {
                            Text("These finish once your server is back and Offline Mode is off.")
                        }
                    }
                }
                if !done.isEmpty {
                    Section("Music") { rows(done, offline) }
                }
                if offline.index.collections.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Download an album or playlist from its menu to play it without a connection."))
                } else {
                    Section {
                        Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        // Retries whatever failed or stopped, and clears the last error.
        // Nothing while offline: OfflineLibrary waits for the server.
        .task {
            disk = state.offline?.diskSpace()
            if let offline = state.offline, let client = state.client { await offline.resume(client: client) }
        }
        .confirmationDialog("Remove every download from this device?", isPresented: $confirmingRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { Task { await state.offline?.removeAll() } }
        }
    }

    @ViewBuilder
    private func rows(_ collections: [OfflineIndex.Collection], _ offline: OfflineLibrary) -> some View {
        ForEach(collections) { collection in
            NavigationLink(value: AppRoute.downloaded(collection.id)) {
                DownloadRow(collection: collection)
            }
            // The Mac has no swipe to delete.
            .contextMenu {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    Task { await offline.remove(collection.id) }
                }
            }
        }
        .onDelete { offsets in
            let ids = offsets.map { collections[$0].id }
            Task { for id in ids { await offline.remove(id) } }
        }
    }

    private func bytes(_ n: some BinaryInteger) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

private struct DownloadRow: View {
    let collection: OfflineIndex.Collection
    @Environment(AppState.self) private var state

    var body: some View {
        let progress = state.offline?.index.progress(collection.id) ?? (done: 0, total: 0)
        HStack(spacing: 12) {
            ArtworkView(itemId: collection.id, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.item.name ?? "Untitled").lineLimit(1)
                Text(progress.done == progress.total
                     ? (progress.total == 1 ? "1 song" : "\(progress.total) songs")
                     : "\(progress.done) of \(progress.total) songs downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.offline?.isTransferring(collection.id) == true {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.circular)
            } else if progress.done < progress.total {
                // Offline nothing transfers: waiting, not failed.
                Image(systemName: state.isOffline ? "pause.circle" : "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(state.isOffline ? "Waiting for your server" : "Some songs did not download")
            }
        }
    }
}

/// One downloaded album or playlist, from the saved copy.
struct DownloadedCollectionView: View {
    let id: String
    @Environment(AppState.self) private var state

    var body: some View {
        let tracks = state.offline?.tracks(of: id) ?? []
        // Only what is on disk is queued: this screen is for playing with no
        // server, where a track still to download would hang, then fail.
        let playable = tracks.filter { state.offline?.localFile($0.id) != nil }
        List {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                let ready = state.offline?.localFile(track.id) != nil
                Button {
                    let start = playable.firstIndex { $0.id == track.id } ?? 0
                    Task { await state.player?.play(playable, startIndex: start) }
                } label: {
                    HStack {
                        TrackRow(track: track)
                        if !ready {
                            Image(systemName: "arrow.down.circle.dotted")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Not downloaded yet")
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!ready)
            }
        }
        .navigationTitle(state.offline?.savedItem(id)?.name ?? "Download")
        .toolbar {
            if !playable.isEmpty {
                Button("Shuffle", systemImage: "shuffle") {
                    Task { await playShuffled(playable, on: state.player) }
                }
            }
        }
    }
}
#endif

/// Download or remove an album or playlist, showing where it stands.
/// Nothing on tvOS.
struct DownloadButton: View {
    let item: JfItem
    @Environment(AppState.self) private var state
    @State private var confirmingRemove = false

    var body: some View {
        #if os(iOS)
        // Offline only a download can be removed: starting one needs the server.
        if let offline = state.offline, offline.isDownloaded(item.id) || !state.isOffline {
            let saved = offline.isDownloaded(item.id)
            let progress = offline.index.progress(item.id)
            Button {
                if saved {
                    confirmingRemove = true
                } else {
                    Task { await state.download(item) }
                }
            } label: {
                Label(saved ? "Downloaded" : "Download",
                      systemImage: !saved ? "arrow.down.circle"
                        : progress.done < progress.total ? "arrow.down.circle.dotted" : "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .confirmationDialog("Remove this download?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { Task { await offline.remove(item.id) } }
            }
        }
        #endif
    }
}
