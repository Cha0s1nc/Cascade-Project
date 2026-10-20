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
    @State private var confirmingDiscard = false
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
                                   description: Text("Download an album or playlist from its menu, or a movie or show from its page, to play it without a connection."))
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
                    @Bindable var state = state
                    Picker("Storage Limit", selection: Binding(get: { state.downloadLimitGB ?? 0 },
                                                                set: { state.downloadLimitGB = $0 })) {
                        ForEach(AppState.downloadLimitChoices, id: \.self) { Text(AppState.limitLabel($0)).tag($0) }
                    }
                } header: {
                    Text("Storage")
                }
                if offline.heldPlays > 0 {
                    // The server's history moved on while this device was
                    // offline (OfflineSync), so the person decides.
                    Section {
                        Button("Add to History") { Task { if let client = state.client { await offline.addHeldPlays(client: client) } } }
                            .disabled(state.isOffline)
                        Button("Discard", role: .destructive) { confirmingDiscard = true }
                    } header: {
                        Text("Plays from Offline")
                    } footer: {
                        let n = offline.heldPlays
                        Text("\(n) \(n == 1 ? "play" : "plays") from while you were offline \(n == 1 ? "was" : "were") not added to your history, because something was played on this account elsewhere meanwhile.")
                    }
                }
                @Bindable var state = state
                Section {
                    Picker("Quality", selection: $state.videoDownloadQuality) {
                        ForEach(VideoQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Remove Watched Episodes", isOn: $state.removeWatchedEpisodes)
                } header: {
                    Text("Movies and TV")
                } footer: {
                    // Beside the setting, as the plan asks: it deletes things.
                    Text(state.removeWatchedEpisodes
                         ? "Watched episodes are removed a day after you finish them. Movies are kept."
                         : "Below Original, the server converts each video, which takes longer.")
                }
                if let message = offline.lastError {
                    Text(message).scaledFont(.footnote).foregroundStyle(.red)
                }
                let downloading = offline.index.collections.filter { !isDone($0, offline) }
                let done = offline.index.collections.filter { isDone($0, offline) }
                let video: Set<String> = ["Movie", "Episode", "Season", "Series"]
                let music = done.filter { !video.contains($0.item.type ?? "") }
                let movies = done.filter { $0.item.type == "Movie" }
                let tv = done.filter { video.contains($0.item.type ?? "") && $0.item.type != "Movie" }
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
                if !music.isEmpty {
                    Section("Music") { rows(music, offline) }
                }
                if !movies.isEmpty {
                    Section("Movies") { rows(movies, offline) }
                }
                if !tv.isEmpty {
                    Section("TV") { rows(tv, offline) }
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
            state.sweepWatchedEpisodes()
            if let offline = state.offline, let client = state.client {
                await offline.resume(client: client)
                await offline.syncFollowed(client: client)
            }
        }
        .confirmationDialog("Discard the plays from while you were offline?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                Task { if let offline = state.offline, let client = state.client { await offline.discardHeldPlays(client: client) } }
            }
        } message: {
            Text("They will not be added to your history.")
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
                if collection.item.type == "Series" {
                    let on = collection.follow != nil
                    Button(on ? "Stop Downloading New Episodes" : "Download New Episodes as They Arrive",
                           systemImage: on ? "bell.slash" : "bell") { offline.setFollow(collection.id, on: !on) }
                }
                Button(offline.index.progress(collection.id).done < offline.index.progress(collection.id).total
                       ? "Cancel Download" : "Remove Download", systemImage: "trash", role: .destructive) {
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
        let type = collection.item.type ?? ""
        let video = ["Movie", "Episode", "Season", "Series"].contains(type)
        let unit = video ? (progress.total == 1 ? "episode" : "episodes") : (progress.total == 1 ? "song" : "songs")
        // The video moving now, which says what the server is doing.
        let transfer = collection.trackIds.lazy.compactMap { state.offline?.transfers[$0] }.first
        HStack(spacing: 12) {
            ArtworkView(itemId: collection.id, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle).lineLimit(1)
                Text(type == "Movie" || type == "Episode"
                     ? (progress.done == progress.total ? (type == "Movie" ? "Movie" : "Episode") : "Waiting")
                     : progress.done == progress.total
                        ? "\(progress.total) \(unit)" + (collection.follow != nil ? " · new episodes download" : "")
                        : "\(progress.done) of \(progress.total) \(unit) downloaded")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if let status = transfer?.status {
                    Text(status).scaledFont(.caption).foregroundStyle(.secondary)
                }
                if let fraction = transfer?.fraction {
                    ProgressView(value: fraction)
                }
            }
            Spacer()
            if state.offline?.isTransferring(collection.id) == true {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.circular)
            } else if progress.done < progress.total {
                // Offline nothing transfers: waiting, not failed.
                Image(systemName: state.isOffline ? "pause.circle" : "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(state.isOffline ? "Waiting for your server" : "Some items did not download")
            }
        }
    }

    /// A season reads as its show's: "Show: Season 2".
    private var rowTitle: String {
        let name = collection.item.name ?? "Untitled"
        if collection.item.type == "Season", let show = collection.item.seriesName { return "\(show): \(name)" }
        return name
    }
}

/// One downloaded album, playlist, movie, season or show, from the saved copy.
struct DownloadedCollectionView: View {
    let id: String
    @Environment(AppState.self) private var state

    private var isVideo: Bool {
        ["Movie", "Episode", "Season", "Series"].contains(state.offline?.index.collection(id)?.item.type ?? "")
    }

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
                    if isVideo { Task { await state.playVideo(playable, startIndex: start) } }
                    else { Task { await state.player?.play(playable, startIndex: start) } }
                } label: {
                    HStack {
                        if isVideo { VideoRow(item: track) } else { TrackRow(track: track) }
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
            if !playable.isEmpty && !isVideo {
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


#if os(iOS) || os(macOS)
extension AppState {
    static func limitLabel(_ gb: Int) -> String { gb == 0 ? "No Limit" : "\(gb) GB" }
}

/// The iPhone asks how much space downloads may take at the first download
/// (the plan's decision); the Mac starts with no limit and never asks.
private struct DownloadLimitQuestion: ViewModifier {
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        @Bindable var state = state
        content.confirmationDialog("How much space may downloads use?", isPresented: $state.askingDownloadLimit,
                                   titleVisibility: .visible) {
            ForEach(AppState.downloadLimitChoices, id: \.self) { gb in
                Button(AppState.limitLabel(gb)) { state.answerDownloadLimit(gb) }
            }
        } message: {
            Text("Downloads stop when they reach it. You can change this in Downloads.")
        }
    }
}

extension View {
    func downloadLimitQuestion() -> some View { modifier(DownloadLimitQuestion()) }
}

/// A downloaded movie or episode in a list: its code, name and length.
private struct VideoRow: View {
    let item: JfItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: item.id, size: 64, aspect: 16.0 / 9.0)
            VStack(alignment: .leading, spacing: 2) {
                Text([VideoPlayback.episodeCode(item), item.name].compactMap { $0 }.joined(separator: "  ")).lineLimit(2)
                if let ticks = item.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
                    Text("\(Int(seconds(fromTicks: ticks) / 60)) min").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.userData?.played == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("Watched")
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
