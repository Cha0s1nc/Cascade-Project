import SwiftUI
import CascadeKit

// The pieces every browsing screen shares, so artwork loading and row layout
// are written and fixed in one place rather than per screen.

/// Decoded covers kept in memory for the session, keyed by item and pixel
/// size. AsyncImage kept nothing: a cover coming back on screen (a tab
/// switch, scrolling back up, returning from an album) waited for its URL,
/// re-read the bytes and decoded them again, and flashed the gray placeholder
/// every time. NSCache gives memory back on its own under pressure.
@MainActor
enum ArtworkCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 << 20   // bytes of decoded pixels
        return cache
    }()
}

/// Album art with a placeholder that keeps the same square footprint, so a grid
/// does not reflow as images arrive. A cover already in ArtworkCache draws on
/// the first frame, with no placeholder at all.
struct ArtworkView: View {
    let itemId: String?
    var size: CGFloat = 160
    /// Fill whatever square the parent proposes rather than a fixed `size`
    /// one, still loading the image for `size`. For artwork whose frame
    /// animates (Now Playing's grows from a header thumbnail), so one sharp
    /// image scales smoothly instead of two copies crossfading.
    var fillsFrame = false
    /// Width over height: 1 for album art, 2/3 for a poster, 16/9 for an
    /// episode still or a backdrop. `size` is the width.
    var aspect: CGFloat = 1
    /// Jellyfin's image type: "Primary", or "Backdrop" for a page's header.
    var imageType = "Primary"

    @Environment(AppState.self) private var state
    /// Tagged with its key: the same view can be handed a different item, and
    /// must not keep showing the last one's cover while the new one loads.
    @State private var loaded: (key: NSString, image: UIImage)?

    private var key: NSString? {
        itemId.map { aspect == 1 && imageType == "Primary" ? "\($0)|\(pixels)" : "\($0)|\(pixels)|\(aspect)|\(imageType)" } as NSString?
    }
    private var pixels: Int { Int(size * 2) }

    var body: some View {
        let image = key.flatMap { key in
            loaded?.key == key ? loaded?.image : ArtworkCache.images.object(forKey: key)
        }
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: aspect == 1 ? "music.note" : "film")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: fillsFrame ? nil : size, height: fillsFrame ? nil : size / aspect)
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(ProportionalRoundedRectangle())
        .task(id: itemId) {
            // The URL carries the token (ApiKey), so it can only be built once
            // there is a signed-in client.
            guard let itemId, let key, let client = state.client else { return }
            if let hit = ArtworkCache.images.object(forKey: key) {
                loaded = (key, hit)
                return
            }
            // A downloaded cover first: with the server away, the network
            // try hangs until it times out, for every cover on screen.
            if let file = state.offline?.artFile(itemId), let data = try? Data(contentsOf: file),
               let decoded = UIImage(data: data) {
                let ready = await decoded.byPreparingForDisplay() ?? decoded
                ArtworkCache.images.setObject(ready, forKey: key,
                                              cost: Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4))
                loaded = (key, ready)
                return
            }
            let url = aspect == 1 && imageType == "Primary"
                ? await client.imageUrl(itemId: itemId, size: pixels)
                : await client.imageUrl(itemId: itemId, type: imageType, width: pixels, height: Int(CGFloat(pixels) / aspect))
            guard let url,
                  let (data, response) = try? await ProxyConnection.shared.session(for: url).data(from: url) else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404 is the normal "this item has no art"; anything else is worth knowing.
            guard status == 200 else {
                if status != 404 { debugLog("cover for item \(itemId): HTTP \(status)") }
                return
            }
            guard let decoded = UIImage(data: data) else {
                debugLog("cover for item \(itemId) did not decode: \(data.count) bytes, \(response.mimeType ?? "no type")")
                return
            }
            // Decoded off the main thread now rather than on it at first draw.
            // Nil here is ImageIO failing on the pixel data itself (the
            // "-17102 decompressing image, possibly corrupt" case): the header
            // parsed, the image did not.
            let prepared = await decoded.byPreparingForDisplay()
            if prepared == nil {
                debugLog("cover for item \(itemId) failed to decode its pixels: \(data.count) bytes, \(response.mimeType ?? "no type")")
            }
            let ready = prepared ?? decoded
            ArtworkCache.images.setObject(ready, forKey: key,
                                          cost: Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4))
            loaded = (key, ready)
        }
    }
}

/// Rounded corners that scale with the shape, so an artwork frame that
/// animates between sizes keeps the same look at every step instead of its
/// corners being fixed at one size's radius.
struct ProportionalRoundedRectangle: Shape {
    var ratio: CGFloat = 0.05

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(rect.width, rect.height) * ratio, style: .continuous).path(in: rect)
    }
}

/// One track in a list. Tapping plays the whole list from that track, which is
/// why this takes the list rather than just the item.
struct TrackRow: View {
    let track: JfItem
    var showsArtwork = true
    /// The long-press menu (TrackMenu.swift). Off in the queue itself.
    var showsMenu = true

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
        // The whole row answers a long press, not just its text.
        .contentShape(Rectangle())
        .modifier(OptionalTrackMenu(track: track, enabled: showsMenu))
    }
}

private struct OptionalTrackMenu: ViewModifier {
    let track: JfItem
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.trackContextMenu(track) } else { content }
    }
}

/// A grid of albums or artists. Both are square art plus two lines, so they
/// share one view rather than two near-identical ones.
struct ItemGrid: View {
    let items: [JfItem]

    var body: some View {
        ScrollView { ItemTiles(items: items) }
    }
}

/// ItemGrid's tiles without the scroll view, for a page that scrolls as a
/// whole (the artist page: its albums sit under its other sections).
struct ItemTiles: View {
    let items: [JfItem]

    #if os(tvOS)
    private let tile: CGFloat = 220
    #else
    private let tile: CGFloat = 150
    #endif

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile), spacing: 16)], spacing: 20) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 6) {
                        ArtworkView(itemId: item.id, size: tile)
                        Text(item.name ?? "Unknown")
                            .font(.caption)
                            .lineLimit(1)
                        // Only what the server actually sent: artists come
                        // without a count, and "0 tracks" under every one
                        // of them was a made-up number.
                        if let subtitle = subtitle(item) {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .itemContextMenu(item)
            }
        }
        .padding()
    }

    private func subtitle(_ item: JfItem) -> String? {
        if let artist = item.albumArtist { return artist }
        if let count = item.childCount { return count == 1 ? "1 song" : "\(count) songs" }
        return nil
    }
}

/// m:ss, h:mm:ss past an hour (a film), or a dash when there is no sensible
/// duration to show.
func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

/// The state every list screen has: loading, loaded, or failed with a reason
/// the user can actually read.
struct LoadingOverlay: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    /// The empty state's symbol: a note, or a film for the video screens.
    var emptySymbol = "music.note"

    var body: some View {
        if isLoading {
            ProgressView()
        } else if let error {
            ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if isEmpty {
            ContentUnavailableView("Nothing here", systemImage: emptySymbol)
        }
    }
}
