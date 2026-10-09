import Foundation
import Observation
import SwiftUI
import CascadeKit

/// The look-and-motion switches added for the crossfade cover slice, the
/// background color fade and Cascade Server's extras, under the desktop's
/// store key names (renderer.js displayPrefs) so the settings import is a copy.
@MainActor
@Observable
final class DisplayPrefs {
    static let shared = DisplayPrefs()

    /// The crossfade cover slice (CoverSlice), and its timings in seconds.
    var coverSlice: Bool { didSet { save(coverSlice, "coverSlice") } }
    var coverSliceIn: Double { didSet { save(coverSliceIn, "coverSliceIn") } }
    var coverSlideOut: Double { didSet { save(coverSlideOut, "coverSlideOut") } }
    /// The Now Playing background's colors fade between songs: over a crossfade,
    /// or in `colorFadeSeconds` for any other change.
    var colorFade: Bool { didSet { save(colorFade, "colorFade") } }
    var colorFadeSeconds: Double { didSet { save(colorFadeSeconds, "colorFadeSeconds") } }
    /// Cascade Server's explicit E and video covers.
    var explicitMarks: Bool { didSet { save(explicitMarks, "explicitMarks") } }
    var videoCovers: Bool { didSet { save(videoCovers, "videoCovers") } }

    static let colorFadeRange = 0.2...2.0

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String) -> Bool { d.object(forKey: "cascade." + k) as? Bool ?? true }
        func number(_ k: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            (d.object(forKey: "cascade." + k) as? Double).map { min(max($0, range.lowerBound), range.upperBound) } ?? fallback
        }
        coverSlice = bool("coverSlice")
        coverSliceIn = number("coverSliceIn", CoverSlice.sliceInDefault, CoverSlice.sliceInRange)
        coverSlideOut = number("coverSlideOut", CoverSlice.slideOutDefault, CoverSlice.slideOutRange)
        colorFade = bool("colorFade")
        colorFadeSeconds = number("colorFadeSeconds", 0.7, Self.colorFadeRange)
        explicitMarks = bool("explicitMarks")
        videoCovers = bool("videoCovers")
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: "cascade." + key) }
}

/// The crossfade cover slice over a cover (CoverSlice): the outgoing cover on
/// top, cut along the diagonal, with the seam (on big covers) and the edge
/// shadow. Draws nothing outside a crossfade that changes the cover, while
/// turned off, or under Reduce Motion. Put it over the incoming cover, in the
/// same frame and clip shape.
struct CoverSliceOverlay: View {
    let player: PlaybackService
    var size: CGFloat = 400
    var showsSeam = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The slice being drawn; cleared once it has slid off, which also stops
    /// the per-frame timeline.
    @State private var live: CrossfadeArt?

    var body: some View {
        let prefs = DisplayPrefs.shared
        ZStack {
            if let art = live {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(art.started)
                    let cutAt = art.cutAt.map { $0.timeIntervalSince(art.started) }
                    if let s = CoverSlice.cut(at: t, fade: art.duration, cutAt: cutAt,
                                              sliceIn: prefs.coverSliceIn, slideOut: prefs.coverSlideOut) {
                        slice(art: art, s: s, glow: CoverSlice.seam(at: t, fade: art.duration, cutAt: cutAt,
                                                                    sliceIn: prefs.coverSliceIn, slideOut: prefs.coverSlideOut))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: player.crossfadeArt) {
            guard let art = player.crossfadeArt, prefs.coverSlice, !reduceMotion else { live = nil; return }
            let leaves = art.started.addingTimeInterval(min(art.cutAt?.timeIntervalSince(art.started) ?? art.duration, art.duration)
                                                        + prefs.coverSlideOut)
            guard leaves > Date() else { live = nil; return }
            live = art
            try? await Task.sleep(for: .seconds(leaves.timeIntervalSinceNow + 0.1))
            if !Task.isCancelled { live = nil }
        }
    }

    private func slice(art: CrossfadeArt, s: Double, glow: Double) -> some View {
        ZStack {
            // The size the cover on screen was loaded at, so this is the cached image, not a fresh decode.
            ArtworkView(itemId: art.outgoing, size: size, fillsFrame: true)
                .mask(DiagonalKeep(s: s))
                .compositingGroup()
                .shadow(color: .black.opacity(0.45), radius: showsSeam ? 6 : 2, x: showsSeam ? 3 : 1, y: showsSeam ? 3 : 1)
            if showsSeam {
                DiagonalSeam(s: s).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .blur(radius: 2.5).opacity(glow * 0.8)
                DiagonalSeam(s: s).stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .opacity(glow)
            }
        }
    }
}

/// The part of the square on the outgoing side of the cut x + y = s.
private struct DiagonalKeep: Shape {
    let s: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let (w, h) = (r.width, r.height)
        if s >= 2 { p.addRect(r); return p }
        if s <= 0 { return p }
        if s >= 1 {
            p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: (s - 1) * h),
                        CGPoint(x: (s - 1) * w, y: h), CGPoint(x: 0, y: h)])
        } else {
            p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: s * w, y: 0), CGPoint(x: 0, y: s * h)])
        }
        p.closeSubpath()
        return p.offsetBy(dx: r.minX, dy: r.minY)
    }
}

/// The cut itself, corner to corner of the part still showing.
private struct DiagonalSeam: Shape {
    let s: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        let (w, h) = (r.width, r.height)
        guard s > 0, s < 2 else { return p }
        if s >= 1 { p.move(to: CGPoint(x: w, y: (s - 1) * h)); p.addLine(to: CGPoint(x: (s - 1) * w, y: h)) }
        else { p.move(to: CGPoint(x: s * w, y: 0)); p.addLine(to: CGPoint(x: 0, y: s * h)) }
        return p.offsetBy(dx: r.minX, dy: r.minY)
    }
}
