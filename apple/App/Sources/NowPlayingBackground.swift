import SwiftUI
import CascadeKit

/// Cover palettes already worked out this session, per item. Extraction is a
/// k-means over 6,400 pixels, cheap but not free, and the same album comes
/// round again track after track.
@MainActor
enum CoverPalettes {
    private static var cache: [String: [BlobColor]] = [:]

    static func palette(for itemId: String, client: JellyfinClient) async -> [BlobColor] {
        if let hit = cache[itemId] { return hit }
        guard let url = await client.imageUrl(itemId: itemId, size: AlbumColors.sampleSide),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let colors = await Task.detached(priority: .utility) { extract(data) }.value
        cache[itemId] = colors
        return colors
    }

    /// The cover drawn into an 80x80 sRGB RGBA buffer, the byte layout
    /// AlbumColors expects (8 bits, premultiplied, alpha last), then clustered.
    nonisolated static func extract(_ data: Data) -> [BlobColor] {
        guard let image = UIImage(data: data)?.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let side = AlbumColors.sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return (try? AlbumColors.extractTopColors(bytes)) ?? []
    }
}

/// The desktop's album-art background: the cover's vivid colours as soft
/// blobs drifting slowly over near-black, at the desktop's ~15 fps. A new
/// cover crossfades in over a second rather than cutting. Still under Reduce
/// Motion.
struct NowPlayingBackground: View {
    /// The album (or track) whose cover sets the colours.
    let itemId: String?

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: [BlobColor] = []
    @State private var drift = AlbumColors.randomizeDrift()
    /// What was showing before the last change, faded out under the new one.
    @State private var previous: (colors: [BlobColor], drift: [DriftParams]) = ([], [])
    @State private var changedAt = Date.distantPast

    private static let fadeSeconds = 1.0

    var body: some View {
        TimelineView(.animation(minimumInterval: AlbumColors.frameInterval, paused: reduceMotion && !isFading)) { timeline in
            let now = timeline.date
            let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
            let fade = min(1, max(0, now.timeIntervalSince(changedAt) / Self.fadeSeconds))
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(.sRGB, red: AlbumColors.base.r, green: AlbumColors.base.g,
                                                blue: AlbumColors.base.b)))
                if fade < 1 {
                    draw(AlbumColors.driftedBlobs(previous.colors, drift: previous.drift, at: t),
                         weight: 1 - fade, in: context, size: size)
                }
                draw(AlbumColors.driftedBlobs(colors, drift: drift, at: t), weight: fade, in: context, size: size)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: itemId) {
            guard let itemId, let client = state.client else { return }
            let fresh = await CoverPalettes.palette(for: itemId, client: client)
            guard !Task.isCancelled, fresh != colors else { return }
            previous = (colors, drift)
            colors = fresh
            // Re-rolled only when the colours change, so the next track of the
            // same album keeps drifting along the same path.
            drift = AlbumColors.randomizeDrift()
            changedAt = .now
        }
    }

    private var isFading: Bool { Date.now.timeIntervalSince(changedAt) < Self.fadeSeconds }

    /// Each blob as the desktop paints it: an ellipse whose radial gradient
    /// holds its colour solid to 42% before falling off to nothing.
    private func draw(_ blobs: [Blob], weight: Double, in context: GraphicsContext, size: CGSize) {
        guard weight > 0 else { return }
        for blob in blobs {
            let rx = blob.w / 100 * size.width
            let ry = blob.h / 100 * size.height
            guard rx > 0, ry > 0 else { continue }
            var layer = context
            layer.translateBy(x: blob.x / 100 * size.width, y: blob.y / 100 * size.height)
            layer.scaleBy(x: 1, y: ry / rx)
            let color = Color(.sRGB, red: blob.color.r / 255, green: blob.color.g / 255,
                              blue: blob.color.b / 255, opacity: blob.alpha * weight)
            let gradient = Gradient(stops: [
                .init(color: color, location: 0),
                .init(color: color, location: 0.42),
                .init(color: color.opacity(0), location: 1),
            ])
            layer.fill(Path(ellipseIn: CGRect(x: -rx, y: -rx, width: rx * 2, height: rx * 2)),
                       with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: rx))
        }
    }
}
