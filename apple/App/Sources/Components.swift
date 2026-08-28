import SwiftUI
import CascadeKit

// The pieces every browsing screen shares, so artwork loading and row layout
// are written and fixed in one place rather than per screen.

/// Album art with a placeholder that keeps the same square footprint, so a grid
/// does not reflow as images arrive.
struct ArtworkView: View {
    let itemId: String?
    var size: CGFloat = 160

    @Environment(AppState.self) private var state
    @State private var url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.05))
        .task(id: itemId) {
            // The URL carries the api_key, so it can only be built once there
            // is a signed-in client.
            guard let itemId, let client = state.client else { return }
            url = await client.imageUrl(itemId: itemId, size: Int(size * 2))
        }
    }
}

/// One track in a list. Tapping plays the whole list from that track, which is
/// why this takes the list rather than just the item.
struct TrackRow: View {
    let track: JfItem
    var showsArtwork = true

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ArtworkView(itemId: track.albumId ?? track.id, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name ?? "Unknown")
                    .lineLimit(1)
                Text(track.albumArtist ?? track.artists?.first ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let ticks = track.runTimeTicks {
                Text(clock(seconds(fromTicks: ticks)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A grid of albums or artists. Both are square art plus two lines, so they
/// share one view rather than two near-identical ones.
struct ItemGrid: View {
    let items: [JfItem]
    let onSelect: (JfItem) -> Void

    #if os(tvOS)
    private let tile: CGFloat = 220
    #else
    private let tile: CGFloat = 150
    #endif

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tile), spacing: 16)], spacing: 20) {
                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(itemId: item.id, size: tile)
                            Text(item.name ?? "Unknown")
                                .font(.caption)
                                .lineLimit(1)
                            Text(item.albumArtist ?? "\(item.childCount ?? 0) tracks")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

/// mm:ss, or a dash when there is no sensible duration to show.
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// The state every list screen has: loading, loaded, or failed with a reason
/// the user can actually read.
struct LoadingOverlay: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool

    var body: some View {
        if isLoading {
            ProgressView()
        } else if let error {
            ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if isEmpty {
            ContentUnavailableView("Nothing here", systemImage: "music.note")
        }
    }
}
