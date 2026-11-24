import SwiftUI
import CascadeKit

struct AlbumDetailView: View {
    let album: JfItem

    @Environment(AppState.self) private var state
    @State private var tracks: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var addingToPlaylist = false

    var body: some View {
        content
            .navigationTitle(album.name ?? "Album")
            .sheet(isPresented: $addingToPlaylist) { AddToPlaylistSheet(tracks: tracks) }
            .task {
                guard let client = state.client else { return }
                do { tracks = try await client.tracks(inAlbum: album.id) }
                catch { self.error = error.localizedDescription }
                isLoading = false
            }
    }

    #if os(macOS)
    @Environment(\.uiScale) private var zoom

    /// Personality v1, as the Penpot "Mac / Album" board and Flutter's AlbumPage: the big
    /// header over the cover's wash, then the songs as numbered rows.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxDetailHeader(label: "Album", title: album.name ?? "Unknown Album", artId: album.id,
                               lead: album.albumArtist,
                               leadId: (album.albumArtists?.first ?? album.artistItems?.first)?.id,
                               meta: macMeta, voice: isLoading ? nil : macVoice) {
                    PillButton("Play", symbol: "play.fill", primary: true) {
                        Task { await state.player?.play(tracks, startIndex: 0) }
                    }
                    .disabled(tracks.isEmpty)
                    PillButton("Shuffle", symbol: "shuffle") { Task { await playShuffled(tracks, on: state.player) } }
                        .disabled(tracks.isEmpty)
                    CxLikeButton(item: album)
                    CxIconButton(symbol: "text.badge.plus", help: "Add to Playlist") { addingToPlaylist = true }
                        .disabled(tracks.isEmpty || state.isOffline)
                }
                VStack(alignment: .leading, spacing: 0) {
                    let groups = discGroups
                    ForEach(groups, id: \.disc) { group in
                        if groups.count > 1 {
                            Text("Disc \(group.disc)").cx(.caps).foregroundStyle(Cx.text3)
                                .padding(.leading, 12).padding(.top, group.disc == groups.first?.disc ? 0 : 18).padding(.bottom, 8)
                        }
                        ForEach(group.tracks, id: \.index) { entry in
                            CxTrackRow(track: entry.track, number: entry.track.indexNumber ?? entry.index + 1) {
                                Task { await state.player?.play(tracks, startIndex: entry.index) }
                            }
                        }
                    }
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty, skeleton: .rows)
                }
                .padding(.horizontal, 36 * zoom).padding(.bottom, 40 * zoom)
            }
        }
    }

    #endif

    /// "2007 · 10 songs, 42m".
    private var macMeta: String {
        let total = tracks.reduce(0.0) { $0 + ($1.runTimeTicks.map(seconds(fromTicks:)) ?? 0) }
        let songs = tracks.isEmpty ? nil : "\(tracks.count == 1 ? "1 song" : "\(tracks.count) songs"), \(QueueMeta.formatSpan(total))"
        return [album.productionYear.map(String.init), songs].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// Flutter's: "You've played it 31 times. Last on Sunday."
    private var macVoice: String {
        let plays = tracks.reduce(0) { $0 + ($1.userData?.playCount ?? 0) }
        if plays == 0 { return "You haven\u{2019}t played it yet." }
        let last = tracks.compactMap { $0.userData?.lastPlayedDate }.max { (PlayHistory.date($0) ?? .distantPast) < (PlayHistory.date($1) ?? .distantPast) }
        let when = PlayHistory.whenPlayed(last)
        return "You\u{2019}ve played it \(plays) \(plays == 1 ? "time" : "times")." + (when.isEmpty ? "" : " Last \(when).")
    }

    #if os(iOS)
    /// Personality v1, as the Penpot "iPhone / Album" board: the centered header, then the
    /// songs as numbered rows with a rule between.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxPhoneDetailHeader(title: album.name ?? "Unknown Album", artId: album.id,
                                    lead: album.albumArtistLine,
                                    leadId: (album.albumArtists?.first ?? album.artistItems?.first)?.id,
                                    meta: macMeta, voice: isLoading ? nil : macVoice) {
                    PillButton("Play", symbol: "play.fill", primary: true, wide: true) {
                        Task { await state.player?.play(tracks, startIndex: 0) }
                    }
                    .disabled(tracks.isEmpty)
                    PillButton("Shuffle", symbol: "shuffle", wide: true) { Task { await playShuffled(tracks, on: state.player) } }
                        .disabled(tracks.isEmpty)
                } icons: {
                    CxLikeButton(item: album)
                    CxIconButton(symbol: "text.badge.plus", help: "Add to Playlist") { addingToPlaylist = true }
                        .disabled(tracks.isEmpty || state.isOffline)
                    DownloadButton(item: album).disabled(tracks.isEmpty)
                }
                VStack(alignment: .leading, spacing: 0) {
                    let groups = discGroups
                    ForEach(groups, id: \.disc) { group in
                        if groups.count > 1 {
                            Text("Disc \(group.disc)").cx(.caps).foregroundStyle(Cx.text3).padding(.top, 14).padding(.bottom, 4)
                        }
                        ForEach(group.tracks, id: \.index) { entry in
                            CxSongRow(track: entry.track, number: entry.track.indexNumber ?? entry.index + 1) {
                                Task { await state.player?.play(tracks, startIndex: entry.index) }
                            }
                            Cx.line.frame(height: 1).padding(.leading, 36)
                        }
                    }
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty, skeleton: .rows)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .toolbarTitleDisplayMode(.inline)
    }
    #elseif os(tvOS)
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if discGroups.count > 1 {
                    ForEach(discGroups, id: \.disc) { group in
                        Text("Disc \(group.disc)")
                            .scaledFont(.headline)
                            .padding(.horizontal)
                        ForEach(group.tracks, id: \.index) { entry in
                            trackRow(entry.track, at: entry.index)
                                .padding(.horizontal)
                        }
                    }
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                        trackRow(track, at: offset)
                            .padding(.horizontal)
                    }
                }
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: tracks.isEmpty, skeleton: .rows)
                    .padding(.horizontal)
            }
        }
    }
    #endif

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemId: album.id, size: 200)
            Text(album.name ?? "Unknown Album")
                .font(.title2.bold())
                .lineLimit(1)
            if let artist = album.albumArtist {
                ArtistLink(name: artist, id: (album.albumArtists?.first ?? album.artistItems?.first)?.id)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(subtitle)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    Task { await state.player?.play(tracks, startIndex: 0) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    Task { await playShuffled(tracks, on: state.player) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                Button {
                    addingToPlaylist = true
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus").labelStyle(.iconOnly)
                }
                .disabled(tracks.isEmpty || state.isOffline)
                DownloadButton(item: album)
                    .disabled(tracks.isEmpty)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.productionYear { parts.append(String(year)) }
        parts.append(tracks.count == 1 ? "1 track" : "\(tracks.count) tracks")
        return parts.joined(separator: " \u{00b7} ")
    }

    /// Grouped by disc so a two-disc album does not read as a flat run of
    /// track numbers that restarts partway through.
    private var discGroups: [(disc: Int, tracks: [(index: Int, track: JfItem)])] {
        let indexed = tracks.enumerated().map { (index: $0.offset, track: $0.element) }
        let grouped = Dictionary(grouping: indexed) { $0.track.parentIndexNumber ?? 1 }
        return grouped.keys.sorted().map { (disc: $0, tracks: grouped[$0]!) }
    }

    private func trackRow(_ track: JfItem, at index: Int) -> some View {
        Button {
            Task { await state.player?.play(tracks, startIndex: index) }
        } label: {
            HStack(spacing: 12) {
                Text(track.indexNumber.map(String.init) ?? "-")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                Text(track.name ?? "Unknown")
                    .lineLimit(1)
                    .explicitMark(track.id)
                Spacer(minLength: 8)
                if let ticks = track.runTimeTicks {
                    Text(clock(seconds(fromTicks: ticks)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .padding(.vertical, 6)
            .desktopTrackRow(track.id)
            #endif
        }
        .buttonStyle(.plain)
        .trackContextMenu(track)
    }
}
