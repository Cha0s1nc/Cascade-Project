import SwiftUI
import CascadeKit

/// Download or remove a movie, an episode, a season or a whole show, showing
/// where it stands. Shared by the iPhone and the Mac; nothing on tvOS, whose
/// storage the system empties as it likes.
///
/// With "Remove watched episodes" on (the iPhone's default), downloading an
/// episode, a season or a show says so first, with a way to turn it off right
/// there: the plan requires it be disclosed where episodes are downloaded,
/// not only in Settings.
struct VideoDownloadButton: View {
    let item: JfItem
    let kind: OfflineLibrary.VideoKind
    /// An icon alone, for an episode row.
    var compact = false
    @Environment(AppState.self) private var state
    @State private var confirmingRemove = false
    @State private var disclosing = false
    @State private var pendingBurnIn: Int?
    /// The pointer is over it: Stop while downloading, Remove once done.
    @State private var hovering = false

    var body: some View {
        #if os(iOS) || os(macOS)
        if let offline = state.offline {
            let saved = offline.isDownloaded(item.id)
            let held = offline.index.collections.contains { $0.trackIds.contains(item.id) }
            if saved || held || !state.isOffline {
                content(offline, saved: saved, held: held)
                    .confirmationDialog("Remove this download?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                        Button("Remove Download", role: .destructive) { Task { await offline.remove(item.id) } }
                    }
                    .confirmationDialog("Watched episodes are removed a day after you finish them.",
                                        isPresented: $disclosing, titleVisibility: .visible) {
                        Button("Download") { start(pendingBurnIn) }
                        Button("Download and Keep Watched Episodes") {
                            state.removeWatchedEpisodes = false
                            start(pendingBurnIn)
                        }
                    } message: {
                        Text("You can change this in Downloads.")
                    }
            }
        }
        #endif
    }

    #if os(iOS) || os(macOS)
    @ViewBuilder
    private func content(_ offline: OfflineLibrary, saved: Bool, held: Bool) -> some View {
        let progress = offline.index.progress(item.id)
        if saved || held {
            let done = held && !saved ? offline.localFile(item.id) != nil : progress.done == progress.total
            let style = compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon)
            let hovered = saved && hovering
            Button {
                if saved { confirmingRemove = true }
            } label: {
                // Stop and Remove are laid over the status, which is always
                // wider, so the button keeps its size under the pointer.
                Label(saved ? (done ? "Downloaded" : "Downloading \(progress.done) of \(progress.total)") : "Downloaded with its season or show",
                      systemImage: done ? "checkmark.circle.fill" : "arrow.down.circle.dotted")
                    .labelStyle(style)
                    .opacity(hovered ? 0 : 1)
                    .overlay {
                        Label(done ? "Remove" : "Stop", systemImage: "xmark").labelStyle(style).opacity(hovered ? 1 : 0)
                    }
            }
            .buttonStyle(.bordered)
            .disabled(!saved)
            .onHover { hovering = $0 }
        } else if !pictureSubtitles.isEmpty {
            // Picture subtitles only exist burned into the picture, which the
            // server converts: offered here, for one video at a time.
            Menu {
                Button("Download") { ask(nil) }
                ForEach(pictureSubtitles, id: \.index) { s in
                    Button("Download with \(s.displayTitle ?? s.language ?? "Subtitles") Burned In") { ask(s.index) }
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .fixedSize()
        } else {
            Button { ask(nil) } label: {
                Label("Download", systemImage: "arrow.down.circle")
                    .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.bordered)
        }
    }

    private var pictureSubtitles: [JfMediaStream] {
        guard kind == .movie || kind == .episode, !compact else { return [] }
        return (item.mediaStreams ?? []).filter { $0.type == "Subtitle" && $0.isTextSubtitleStream == false && $0.index != nil }
    }

    private func ask(_ burnIn: Int?) {
        pendingBurnIn = burnIn
        if kind != .movie && state.removeWatchedEpisodes { disclosing = true } else { start(burnIn) }
    }

    private func start(_ burnIn: Int?) {
        Task { await state.downloadVideo(item, kind: kind, burnIn: burnIn) }
    }
    #endif
}

/// "Download new episodes as they arrive" for a show, shown once it is
/// downloaded or downloading (the Downloads screen has the same switch).
struct FollowSeriesToggle: View {
    let seriesId: String
    @Environment(AppState.self) private var state

    var body: some View {
        #if os(iOS) || os(macOS)
        if let offline = state.offline, offline.isDownloaded(seriesId) {
            Toggle("Download new episodes as they arrive", isOn: Binding(
                get: { offline.index.collection(seriesId)?.follow != nil },
                set: { offline.setFollow(seriesId, on: $0) }))
            .toggleStyle(.switch)
        }
        #endif
    }
}

/// Either label style, chosen at run time.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
