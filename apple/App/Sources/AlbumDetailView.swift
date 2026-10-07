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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if discGroups.count > 1 {
                    ForEach(discGroups, id: \.disc) { group in
                        Text("Disc \(group.disc)")
                            .font(.headline)
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
        .navigationTitle(album.name ?? "Album")
        .sheet(isPresented: $addingToPlaylist) { AddToPlaylistSheet(tracks: tracks) }
        .task {
            guard let client = state.client else { return }
            do { tracks = try await client.tracks(inAlbum: album.id) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemId: album.id, size: 200)
            Text(album.name ?? "Unknown Album")
                .font(.title2.bold())
                .lineLimit(1)
            if let artist = album.albumArtist {
                Text(artist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.caption)
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
                .disabled(tracks.isEmpty)
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
                Spacer(minLength: 8)
                if let ticks = track.runTimeTicks {
                    Text(clock(seconds(fromTicks: ticks)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .trackContextMenu(track)
    }
}
