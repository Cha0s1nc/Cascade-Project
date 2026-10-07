import SwiftUI
import CascadeKit

/// Cover palettes already worked out this session, per item. Extraction is a
/// k-means over 6,400 pixels, cheap but not free, and the same album comes
/// round again track after track.
@MainActor
enum CoverPalettes {
    /// Keyed by the theme too: the light one clamps blobs into a different lightness window
    /// than the dark one, so a palette is only right for the theme it was extracted for.
    private static var cache: [String: [BlobColor]] = [:]

    static func palette(for itemId: String, client: JellyfinClient, light: Bool = false) async -> [BlobColor] {
        let key = "\(itemId)|\(light)"
        if let hit = cache[key] { return hit }
        guard let url = await client.imageUrl(itemId: itemId, size: AlbumColors.sampleSide),
              let (data, response) = try? await ProxyConnection.shared.session(for: url).data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let colors = await Task.detached(priority: .utility) { extract(data, light: light) }.value
        cache[key] = colors
        return colors
    }

    /// The cover drawn into an 80x80 sRGB RGBA buffer, the byte layout
    /// AlbumColors expects (8 bits, premultiplied, alpha last), then clustered.
    nonisolated static func extract(_ data: Data, light: Bool = false) -> [BlobColor] {
        guard let image = PlatformImage(data: data)?.cgImage,
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
        return (try? AlbumColors.extractTopColors(bytes, light: light)) ?? []
    }
}

/// What the Now Playing background is showing: the current cover's colours,
/// their drift, and what they are crossfading from. Shared and long-lived
/// rather than @State in the background view, because the sheet is rebuilt on
/// every presentation: kept per view, a reopened player started from nothing,
/// and the palette could land on a copy of the view that was no longer the
/// one on screen, which left the background blank. Now a reopened player
/// draws its colours on the first frame.
@MainActor
@Observable
final class CoverBackdrop {
    static let shared = CoverBackdrop()

    private(set) var itemId: String?
    /// The theme the colours were worked out for.
    private(set) var light = false
    private(set) var colors: [BlobColor] = []
    private(set) var drift = AlbumColors.randomizeDrift()
    /// What was showing before the last change, faded out under the new one.
    private(set) var previous: (colors: [BlobColor], drift: [DriftParams]) = ([], [])
    private(set) var changedAt = Date.distantPast
    @ObservationIgnored private var requested: String?

    /// Show this cover's colours, crossfading from whatever is up. The one place the
    /// background's colours are set (the desktop's setOverlayBackgroundImage): it skips
    /// when the cover and the theme are what is already showing, and a theme switch
    /// re-extracts, since each theme clamps blobs into its own lightness window.
    func show(itemId: String?, client: JellyfinClient?, light: Bool = false) async {
        guard itemId != self.itemId || light != self.light || colors.isEmpty else { return }
        requested = itemId
        let fresh: [BlobColor]
        if let itemId, let client {
            fresh = await CoverPalettes.palette(for: itemId, client: client, light: light)
        } else {
            fresh = []
        }
        // A newer track asked while this one was loading.
        guard requested == itemId else { return }
        self.itemId = itemId
        self.light = light
        guard fresh != colors else { return }
        previous = (colors, drift)
        colors = fresh
        // Re-rolled only when the colours change, so the next track of the
        // same album keeps drifting along the same path.
        drift = AlbumColors.randomizeDrift()
        changedAt = .now
    }
}

/// The desktop's album-art background: the cover's vivid colours as soft
/// blobs drifting slowly over near-black, at the desktop's ~15 fps. A new
/// cover crossfades in over a second rather than cutting. Still, and switched
/// without the crossfade, under Reduce Motion.
struct NowPlayingBackground: View {
    /// The album (or track) whose cover sets the colours.
    let itemId: String?
    /// Lyrics are in front, so darken: more for a bright cover, whose light
    /// blobs otherwise swallow the faint upcoming lines.
    var behindLyrics = false
    /// The Mac's light theme: blobs clamped to the light lightness window over a near-white
    /// base, not darkened behind lyrics (the overlay lays its own scrims instead).
    var light = false
    /// The light theme paints the blobs with multiply, like ink on paper (the desktop's
    /// --np-blend); off, they are laid on as they are. Dark ignores it.
    var multiply = true

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let fadeSeconds = 1.0

    var body: some View {
        let backdrop = CoverBackdrop.shared
        let (colors, drift, previous, changedAt) = (backdrop.colors, backdrop.drift, backdrop.previous, backdrop.changedAt)
        let tune = StyleTuning.shared.values
        TimelineView(.animation(minimumInterval: AlbumColors.frameInterval, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate * tune.bgSpeed
            // Under Reduce Motion the timeline is paused and its date stale,
            // so a fade measured against it could sit at zero forever.
            let fade = reduceMotion ? 1 : min(1, max(0, now.timeIntervalSince(changedAt) / Self.fadeSeconds))
            Canvas { context, size in
                let base = light ? AlbumColors.baseLight : AlbumColors.base
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(.sRGB, red: base.r, green: base.g, blue: base.b)))
                var inked = context
                if light && multiply { inked.blendMode = .multiply }
                if fade < 1 {
                    draw(AlbumColors.driftedBlobs(previous.colors, drift: previous.drift, at: t, light: light),
                         weight: (1 - fade) * tune.bgIntensity, in: inked, size: size)
                }
                draw(AlbumColors.driftedBlobs(colors, drift: drift, at: t, light: light), weight: fade * tune.bgIntensity,
                     in: inked, size: size)
            }
            // The tuning panel's colour knobs; at their defaults, no-ops.
            .saturation(tune.bgSaturation)
            .brightness(tune.bgBrightness)
            .blur(radius: tune.bgBlur, opaque: true)
        }
        .overlay {
            Color.black
                .opacity(behindLyrics && !light ? Self.lyricsDim(colors, tune) : 0)
                .animation(.easeInOut(duration: 0.6), value: behindLyrics)
                .animation(.easeInOut(duration: Self.fadeSeconds), value: colors)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: "\(itemId ?? "")|\(light)") {
            await CoverBackdrop.shared.show(itemId: itemId, client: state.client, light: light)
        }
    }

    static func lyricsDim(_ colors: [BlobColor], _ tune: StyleTuning.Values) -> Double {
        let span = max(0.82 - tune.lyricsDimFrom, 0.01)
        let bright = min(1, max(0, (AlbumColors.brightness(colors) - tune.lyricsDimFrom) / span))
        return min(1, tune.lyricsDimBase + tune.lyricsDimBright * bright)
    }

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
                              blue: blob.color.b / 255, opacity: min(1, blob.alpha * weight))
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
