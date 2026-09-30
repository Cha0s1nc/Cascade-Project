import Foundation

// The album-art background: a few vivid colours pulled out of a cover, drifting
// around as blobs. A port of the desktop's src/core/album-colors.ts (dark theme
// only, since Now Playing is always dark here), so the phone paints the same
// background from the same cover rather than a lookalike. Pure: raw RGBA bytes
// and a timestamp in, numbers out. Getting the pixels and painting the blobs
// are the app's business.

/// A blob colour, 0-255 per channel. `hue` is reporting only.
public struct BlobColor: Sendable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var hue: Double
}

/// A blob placed on screen. Positions and sizes are percentages of the view.
public struct Blob: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var alpha: Double
    public var color: BlobColor
}

/// Per-blob drift: two sin/cos pairs per axis with incommensurate periods, so
/// the path is a slow Lissajous figure that does not visibly repeat.
public struct DriftParams: Sendable, Equatable {
    var xF1, xP1, xA1, xF2, xP2, xA2: Double
    var yF1, yP1, yA1, yF2, yP2, yA2: Double
}

public enum AlbumColors {
    /// The base the blobs sit on. The desktop overlay's #0d0d0f.
    public static let base = (r: 13.0 / 255, g: 13.0 / 255, b: 15.0 / 255)

    /// How often a host should move the blobs. The drift has periods of tens of
    /// seconds, so 60 fps is wasted work; the desktop runs at ~15.
    public static let frameInterval: Double = 0.066

    /// The side of the square the cover should be scaled to before extraction:
    /// what the desktop's k-means was tuned on (6,400 px).
    public static let sampleSide = 80

    public struct NotPackedRGBA: Error {}

    // MARK: Oklab
    //
    // Clustered in Oklab rather than by hue: navy and sky blue share a hue
    // and average into mud, and a colour on a hue-bucket edge splits its vote.
    // Oklab is perceptually uniform, so plain distance means "looks this
    // different", which is exactly the judgement being made.

    struct Oklab: Equatable { var L: Double; var a: Double; var b: Double }

    static func srgbToLinear(_ c: Double) -> Double {
        let n = c / 255
        return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
    }

    static func linearToSrgb(_ c: Double) -> Double {
        let n = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return min(255, max(0, (n * 255).rounded()))
    }

    static func oklab(r: Double, g: Double, b: Double) -> Oklab {
        let lr = srgbToLinear(r), lg = srgbToLinear(g), lb = srgbToLinear(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return Oklab(L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func srgb(_ c: Oklab) -> (r: Double, g: Double, b: Double) {
        let l_ = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m_ = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s_ = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (linearToSrgb(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                linearToSrgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                linearToSrgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    static func chroma(_ c: Oklab) -> Double { hypot(c.a, c.b) }

    static func distance(_ p: Oklab, _ q: Oklab) -> Double {
        (pow(p.L - q.L, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2)).squareRoot()
    }

    static func hueOf(_ c: Oklab) -> Double {
        let deg = atan2(c.b, c.a) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Clusters found before ranking: more than are returned, so a small vivid
    /// accent gets its own cluster instead of being absorbed by a big dull one.
    static let clusters = 5
    static let iterations = 12
    /// Without a minimum gap the top three are routinely three shades of one
    /// thing, which reads as a one-colour background.
    static let minSeparation = 0.12
    /// Dark theme lightness window: below it a blob is lost on #0d0d0f, above
    /// it washes out the content in front.
    static let minL = 0.45, maxL = 0.82
    /// Below this a colour reads as grey rather than as a colour.
    static let minChroma = 0.06

    // MARK: Extraction

    /// The dominant vivid colours of a cover, most prominent first.
    ///
    /// `rgba` is tightly packed RGBA, 4 bytes a pixel; any other length means
    /// the caller mislabelled its buffer, and reading past a row would give
    /// plausible garbage, so it throws. Deterministic: the same cover always
    /// gives the same colours, or the background would change between plays.
    public static func extractTopColors(_ rgba: [UInt8], count n: Int = 3) throws -> [BlobColor] {
        guard rgba.count % 4 == 0 else { throw NotPackedRGBA() }

        // Near-black and near-white say nothing about a palette (every cover
        // has plenty of both), so they are dropped. Loose on purpose: a dark
        // cover should still give its dark colours.
        var samples: [Oklab] = []
        samples.reserveCapacity(rgba.count / 4)
        var i = 0
        while i < rgba.count {
            if rgba[i + 3] >= 128 {
                let c = oklab(r: Double(rgba[i]), g: Double(rgba[i + 1]), b: Double(rgba[i + 2]))
                if c.L >= 0.08 && c.L <= 0.97 { samples.append(c) }
            }
            i += 4
        }
        if samples.isEmpty { return [] }

        var centroids = seedCentroids(samples, k: clusters)
        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<iterations {
            var moved = false
            for (i, s) in samples.enumerated() {
                var best = 0, bestD = Double.infinity
                for (k, c) in centroids.enumerated() {
                    let d = distance(s, c)
                    if d < bestD { bestD = d; best = k }
                }
                if assignment[i] != best { assignment[i] = best; moved = true }
            }
            var sums = [(L: Double, a: Double, b: Double, n: Int)](repeating: (0, 0, 0, 0), count: centroids.count)
            for (i, s) in samples.enumerated() {
                let k = assignment[i]
                sums[k].L += s.L; sums[k].a += s.a; sums[k].b += s.b; sums[k].n += 1
            }
            for k in centroids.indices where sums[k].n > 0 {
                let n = Double(sums[k].n)
                centroids[k] = Oklab(L: sums[k].L / n, a: sums[k].a / n, b: sums[k].b / n)
            }
            if !moved { break }
        }

        // Share of the cover times colourfulness, so a vivid accent beats a
        // large dull field: 80% beige and 5% hot pink should read as pink.
        var counts = [Int](repeating: 0, count: centroids.count)
        for a in assignment { counts[a] += 1 }
        let ranked = centroids.enumerated()
            .map { k, c -> (c: Oklab, share: Double, score: Double) in
                let share = Double(counts[k]) / Double(samples.count)
                return (c, share, share * pow(chroma(c) + 0.02, 1.5))
            }
            .filter { $0.share > 0.01 }
            // Stable on ties, like the desktop's Array.sort.
            .enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)

        var picked: [Oklab] = []
        for r in ranked where picked.count < n {
            if picked.contains(where: { distance($0, r.c) < minSeparation }) { continue }
            picked.append(r.c)
        }
        // A genuinely monochrome cover: backfill rather than hand the layout
        // fewer blobs than it expects.
        for r in ranked where picked.count < n && !picked.contains(r.c) {
            picked.append(r.c)
        }
        return picked.map(blobColor)
    }

    /// Deterministic k-means++ style seeding: the most colourful sample, then
    /// repeatedly the sample furthest from everything chosen. Random seeding
    /// would give the same cover different colours on different plays.
    static func seedCentroids(_ samples: [Oklab], k: Int) -> [Oklab] {
        var first = samples[0], bestChroma = -1.0
        for s in samples where chroma(s) > bestChroma { bestChroma = chroma(s); first = s }
        var centroids = [first]
        while centroids.count < k && centroids.count < samples.count {
            var far = samples[0], farD = -1.0
            for s in samples {
                let nearest = centroids.map { distance(s, $0) }.min() ?? .infinity
                if nearest > farD { farD = nearest; far = s }
            }
            centroids.append(far)
        }
        return centroids
    }

    /// A cluster centre as a paintable colour. Left alone unless it would be
    /// invisible against the base, then only nudged to the edge of the usable
    /// window; the hue is never touched.
    static func blobColor(_ c: Oklab) -> BlobColor {
        var (L, a, b) = (c.L, c.a, c.b)
        L = min(maxL, max(minL, L))
        let ch = hypot(a, b)
        if ch > 0 && ch < minChroma {
            let scale = minChroma / ch
            a *= scale
            b *= scale
        }
        let rgb = srgb(Oklab(L: L, a: a, b: b))
        return BlobColor(r: rgb.r, g: rgb.g, b: rgb.b, hue: hueOf(c))
    }

    // MARK: Drift

    /// Fresh drift, one set per blob. Re-rolled on every colour change so two
    /// tracks in a row do not trace the same path. `random` is injectable only
    /// so a test can pin it.
    public static func randomizeDrift(count: Int = 3,
                                      random: () -> Double = { Double.random(in: 0..<1) }) -> [DriftParams] {
        (0..<count).map { _ in
            DriftParams(xF1: 0.11 + random() * 0.13, xP1: random() * .pi * 2, xA1: 10 + random() * 10,
                        xF2: 0.04 + random() * 0.09, xP2: random() * .pi * 2, xA2: 3 + random() * 6,
                        yF1: 0.10 + random() * 0.13, yP1: random() * .pi * 2, yA1: 10 + random() * 10,
                        yF2: 0.04 + random() * 0.09, yP2: random() * .pi * 2, yA2: 3 + random() * 6)
        }
    }

    /// Anchors in percent, near the edges so the middle stays dark enough to
    /// read over: the background is a mood, not a competitor to the content.
    static let slots: [(x: Double, y: Double, w: Double, h: Double, alpha: Double)] = [
        (78, 16, 78, 78, 0.88),
        (18, 82, 78, 78, 0.80),
        (12, 18, 58, 58, 0.55),
    ]

    /// How light the background reads, 0 to 1: the blobs' Oklab lightness,
    /// weighted by how much of the screen each covers (its slot's size and
    /// opacity). 0 with no colours, when the near-black base is all there is.
    public static func brightness(_ colors: [BlobColor]) -> Double {
        let weighted = zip(colors, slots).map { c, s in (oklab(r: c.r, g: c.g, b: c.b).L, s.w * s.h * s.alpha) }
        let total = weighted.reduce(0) { $0 + $1.1 }
        return total > 0 ? weighted.reduce(0) { $0 + $1.0 * $1.1 } / total : 0
    }

    /// Where the blobs are at time `t` in seconds. Pure: a host drives it from a
    /// clock, a test from a constant.
    public static func driftedBlobs(_ colors: [BlobColor], drift: [DriftParams], at t: Double) -> [Blob] {
        colors.enumerated().map { i, color in
            let s = i < slots.count ? slots[i] : slots[2]
            guard let p = i < drift.count ? drift[i] : drift.first else {
                return Blob(x: s.x, y: s.y, w: s.w, h: s.h, alpha: s.alpha, color: color)
            }
            return Blob(x: s.x + sin(t * p.xF1 + p.xP1) * p.xA1 + sin(t * p.xF2 + p.xP2) * p.xA2,
                        y: s.y + cos(t * p.yF1 + p.yP1) * p.yA1 + cos(t * p.yF2 + p.yP2) * p.yA2,
                        w: s.w, h: s.h, alpha: s.alpha, color: color)
        }
    }
}
