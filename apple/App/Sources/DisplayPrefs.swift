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
    /// How it looks and moves; the seam glow and edge shadow are times their default strength.
    var coverSliceStyle: CoverSlice.Style { didSet { save(coverSliceStyle.rawValue, "coverSliceStyle") } }
    var coverSliceDirection: CoverSlice.Direction { didSet { save(coverSliceDirection.rawValue, "coverSliceDirection") } }
    var coverSliceHold: CoverSlice.Hold { didSet { save(coverSliceHold.rawValue, "coverSliceHold") } }
    var coverSliceEasing: CoverSlice.Easing { didSet { save(coverSliceEasing.rawValue, "coverSliceEasing") } }
    var coverSliceSeam: CoverSlice.Seam { didSet { save(coverSliceSeam.rawValue, "coverSliceSeam") } }
    var coverSliceGlow: Double { didSet { save(coverSliceGlow, "coverSliceGlow") } }
    var coverSliceShadow: Double { didSet { save(coverSliceShadow, "coverSliceShadow") } }
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
        func choice<T: RawRepresentable>(_ k: String, _ fallback: T) -> T where T.RawValue == String {
            d.string(forKey: "cascade." + k).flatMap(T.init(rawValue:)) ?? fallback
        }
        coverSlice = bool("coverSlice")
        coverSliceStyle = choice("coverSliceStyle", .slice)
        coverSliceDirection = choice("coverSliceDirection", .upLeft)
        coverSliceHold = choice("coverSliceHold", .half)
        coverSliceEasing = choice("coverSliceEasing", .smooth)
        coverSliceSeam = choice("coverSliceSeam", .white)
        coverSliceGlow = number("coverSliceGlow", 1, CoverSlice.strengthRange)
        coverSliceShadow = number("coverSliceShadow", 1, CoverSlice.strengthRange)
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
/// top, cut, faded or pushed as DisplayPrefs says, with the seam (on big
/// covers) and the edge shadow. Draws nothing outside a crossfade that changes
/// the cover, while turned off, or under Reduce Motion. Put it over the
/// incoming cover, in the same frame and clip shape.
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
                    if let s = CoverSlice.cut(at: t, fade: art.duration, cutAt: cutAt, sliceIn: prefs.coverSliceIn,
                                              slideOut: prefs.coverSlideOut, hold: prefs.coverSliceHold, easing: prefs.coverSliceEasing) {
                        slice(art: art, s: s, prefs: prefs,
                              glow: CoverSlice.seam(at: t, fade: art.duration, cutAt: cutAt, sliceIn: prefs.coverSliceIn,
                                                    slideOut: prefs.coverSlideOut, hold: prefs.coverSliceHold, easing: prefs.coverSliceEasing))
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

    @ViewBuilder
    private func slice(art: CrossfadeArt, s: Double, prefs: DisplayPrefs, glow: Double) -> some View {
        let move = prefs.coverSliceDirection.move
        let shadow = Color.black.opacity(0.45 * prefs.coverSliceShadow)
        let (radius, offset): (CGFloat, CGFloat) = showsSeam ? (6, 3) : (2, 1)
        // The size the cover on screen was loaded at, so this is the cached image, not a fresh decode.
        let outgoing = ArtworkView(itemId: art.outgoing, size: size, fillsFrame: true)
        switch prefs.coverSliceStyle {
        case .fade:
            outgoing.opacity(s / 2)
        case .push:
            // ponytail: a diagonal push would leave two corners empty, so it pushes sideways only.
            let (px, py) = prefs.coverSliceDirection.isDiagonal ? (move.x, 0) : move
            let along = 1 - s / 2
            GeometryReader { g in
                ZStack {
                    outgoing.offset(x: px * along * g.size.width, y: py * along * g.size.height)
                    ArtworkView(itemId: art.incoming, size: size, fillsFrame: true)
                        .shadow(color: shadow, radius: radius)
                        .offset(x: px * (along - 1) * g.size.width, y: py * (along - 1) * g.size.height)
                }
            }
        case .slice:
            let seam = prefs.coverSliceSeam
            let color = seam == .accent ? Color.accentColor : .white
            ZStack {
                outgoing
                    .mask(SliceCut(s: s, move: move))
                    .compositingGroup()
                    .shadow(color: shadow, radius: radius, x: -move.x * offset, y: -move.y * offset)
                if showsSeam && seam != .off {
                    SliceCut(s: s, move: move, edgeOnly: true).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .blur(radius: 2.5 * prefs.coverSliceGlow).opacity(min(1, glow * 0.8 * prefs.coverSliceGlow))
                    SliceCut(s: s, move: move, edgeOnly: true).stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .opacity(glow)
                }
            }
        }
    }
}

/// The part of the square still on the outgoing side of the cut, or the cut
/// itself (`edgeOnly`). Drawn for a cut moving up and left (x + y = s) or
/// straight left or up (at s / 2 across), then mirrored for the other ways.
private struct SliceCut: Shape {
    let s: Double
    let move: (x: Double, y: Double)
    var edgeOnly = false

    func path(in r: CGRect) -> Path {
        var p = Path()
        let (w, h) = (r.width, r.height)
        guard s > 0, s < 2 else {
            if s >= 2 && !edgeOnly { p.addRect(r) }
            return p
        }
        if move.x != 0 && move.y != 0 {
            let points = s >= 1
                ? [CGPoint(x: w, y: (s - 1) * h), CGPoint(x: (s - 1) * w, y: h)]
                : [CGPoint(x: s * w, y: 0), CGPoint(x: 0, y: s * h)]
            if edgeOnly { p.addLines(points) }
            else if s >= 1 { p.addLines([CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)] + points + [CGPoint(x: 0, y: h)]); p.closeSubpath() }
            else { p.addLines([CGPoint(x: 0, y: 0)] + points); p.closeSubpath() }
        } else if move.y == 0 {
            let x = s / 2 * w
            if edgeOnly { p.addLines([CGPoint(x: x, y: 0), CGPoint(x: x, y: h)]) } else { p.addRect(CGRect(x: 0, y: 0, width: x, height: h)) }
        } else {
            let y = s / 2 * h
            if edgeOnly { p.addLines([CGPoint(x: 0, y: y), CGPoint(x: w, y: y)]) } else { p.addRect(CGRect(x: 0, y: 0, width: w, height: y)) }
        }
        let flipX = move.x > 0, flipY = move.y > 0
        let mirror = CGAffineTransform(a: flipX ? -1 : 1, b: 0, c: 0, d: flipY ? -1 : 1, tx: flipX ? w : 0, ty: flipY ? h : 0)
        return p.applying(mirror).offsetBy(dx: r.minX, dy: r.minY)
    }
}

#if !os(tvOS)
/// Settings for DisplayPrefs: the crossfade cover slice, the background color
/// fade, and Cascade Server's explicit marks and video covers. The Mac's
/// Playback tab and the iPhone's Settings show it.
struct DisplaySettingsSection: View {
    @Bindable private var prefs = DisplayPrefs.shared

    var body: some View {
        Section {
            Toggle("Animate covers on crossfade", isOn: $prefs.coverSlice)
            if prefs.coverSlice {
                picker("Style", $prefs.coverSliceStyle, ["Slice", "Fade", "Push"])
                if prefs.coverSliceStyle != .fade {
                    picker("Direction", $prefs.coverSliceDirection,
                           ["Up and left", "Up", "Up and right", "Right", "Down and right", "Down", "Down and left", "Left"])
                }
                picker("Hold", $prefs.coverSliceHold, ["Half and half", "Mostly the old cover", "Mostly the new cover", "No hold, sweep across the fade"])
                if prefs.coverSliceHold != .sweep { seconds("Cut in", $prefs.coverSliceIn, CoverSlice.sliceInRange) }
                seconds("Slide out", $prefs.coverSlideOut, CoverSlice.slideOutRange)
                picker("Easing", $prefs.coverSliceEasing, ["Smooth", "Snappy", "Linear"])
                if prefs.coverSliceStyle == .slice {
                    picker("Seam", $prefs.coverSliceSeam, ["White", "Accent color", "Off"])
                    if prefs.coverSliceSeam != .off { percent("Seam glow", $prefs.coverSliceGlow) }
                }
                if prefs.coverSliceStyle != .fade { percent("Edge shadow", $prefs.coverSliceShadow) }
            }
            Toggle("Fade background colors between songs", isOn: $prefs.colorFade)
            if prefs.colorFade { seconds("Fade on skip", $prefs.colorFadeSeconds, DisplayPrefs.colorFadeRange) }
        } header: {
            Text("Transitions")
        } footer: {
            Text("During a crossfade the old cover makes way for the new one (Slice cuts it away, Fade dissolves it, Push slides the new one in; a diagonal push goes straight sideways) and the background's colors fade with the music; on a skip the colors fade for the set time. The slice needs Crossfade on; the color fade needs the album-art colors. Reduce Motion turns both off.")
        }
        Section {
            Toggle("Explicit marks", isOn: $prefs.explicitMarks)
            Toggle("Video covers", isOn: $prefs.videoCovers)
        } header: {
            Text("Cascade Server")
        } footer: {
            Text("With Cascade Server 1.1 on your server: an E after explicit songs, and an album's cover.mp4 playing in place of its cover.")
        }
    }

    /// A menu over a CoverSlice choice, its cases labeled in order.
    private func picker<T: CaseIterable & Hashable>(_ name: String, _ value: Binding<T>, _ labels: [String]) -> some View
    where T.AllCases: RandomAccessCollection {
        Picker(name, selection: value) {
            ForEach(Array(zip(T.allCases, labels)), id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func percent(_ name: String, _ value: Binding<Double>) -> some View {
        LabeledContent(name) {
            HStack {
                Slider(value: value, in: CoverSlice.strengthRange, step: 0.05).frame(maxWidth: 180).accessibilityLabel(name)
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func seconds(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(name) {
            HStack {
                Slider(value: value, in: range, step: 0.1).frame(maxWidth: 180).accessibilityLabel(name)
                Text(String(format: "%.1f s", value.wrappedValue)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}
#endif

/// A message an admin sent from Jellyfin's dashboard (AppState.serverMessage): a card at
/// the top until closed, or for as long as the sender asked. Text only.
struct ServerMessageCard: ViewModifier {
    @Environment(AppState.self) private var state

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = state.serverMessage {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.header).font(.callout.weight(.semibold))
                        if !message.text.isEmpty {
                            Text(message.text).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { close(message) } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                }
                // As tall as the text: the stripe alone would stretch it down the window.
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .task(id: message.id) {
                    guard let timeout = message.timeout else { return }
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { close(message) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: state.serverMessage?.id)
    }

    private func close(_ message: ServerMessage) {
        if state.serverMessage?.id == message.id { state.serverMessage = nil }
    }
}

extension View {
    func serverMessages() -> some View { modifier(ServerMessageCard()) }
}
