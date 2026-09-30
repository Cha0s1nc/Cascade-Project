import SwiftUI
import CascadeKit

#if os(iOS)
/// Downloaded albums and playlists. Drawn entirely from what was saved, so
/// it works with no server at all, which is the point of it. tvOS has no
/// downloads: its storage is a cache the system empties as it likes.
struct DownloadsView: View {
    @Environment(AppState.self) private var state
    @State private var confirmingRemoveAll = false

    var body: some View {
        List {
            if let offline = state.offline {
                if let message = offline.lastError {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                ForEach(offline.index.collections) { collection in
                    NavigationLink(value: AppRoute.downloaded(collection.id)) {
                        DownloadRow(collection: collection)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { offline.index.collections[$0].id }
                    Task { for id in ids { await offline.remove(id) } }
                }
                if offline.index.collections.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Download an album or playlist from its menu to play it without a connection."))
                } else {
                    Section {
                        Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                    } footer: {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(offline.index.totalBytes), countStyle: .file)) on this iPhone")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Remove every download from this device?", isPresented: $confirmingRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove All", role: .destructive) { Task { await state.offline?.removeAll() } }
        }
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
            if progress.done < progress.total {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.circular)
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
        List {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    Task { await state.player?.play(tracks, startIndex: index) }
                } label: {
                    HStack {
                        TrackRow(track: track)
                        if state.offline?.localFile(track.id) == nil {
                            Image(systemName: "arrow.down.circle.dotted")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Not downloaded yet")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(state.offline?.savedItem(id)?.name ?? "Download")
        .toolbar {
            if !tracks.isEmpty {
                Button("Shuffle", systemImage: "shuffle") {
                    Task { await playShuffled(tracks, on: state.player) }
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
        if let offline = state.offline {
            let saved = offline.isDownloaded(item.id)
            let progress = offline.index.progress(item.id)
            Button {
                if saved {
                    confirmingRemove = true
                } else if let client = state.client {
                    Task { await offline.download(item, client: client) }
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
