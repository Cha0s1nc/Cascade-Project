import SwiftUI
import CascadeKit

/// Loads the current track's lyrics from the server's Cascade plugin, for the
/// Now Playing screen. Views read `lines`: nil while loading or when the track
/// has none, which `isLoading` tells apart.
@MainActor
@Observable
final class LyricsModel {
    private(set) var lines: [LyricLine]?
    /// True from a track change until its lyrics are in (or known missing).
    /// Without it, the brief nil between two tracks read as "this song has no
    /// lyrics", and Now Playing left lyrics mode on every skip.
    private(set) var isLoading = false
    /// Track and route last loaded. The route is part of it because the plugin
    /// probe can finish after Now Playing opens, and then it is worth asking.
    private var loadedKey: String?

    func load(itemId: String?, client: JellyfinClient?, api: CascadePluginApi?) async {
        let key = "\(itemId ?? "")|\(String(describing: api))"
        guard key != loadedKey else { return }
        lines = nil
        loadedKey = key
        #if DEBUG
        // Launch with -cascade.debugLyrics YES to style-check lyrics against a
        // server with no Cascade plugin (the local test server has none).
        if UserDefaults.standard.bool(forKey: "cascade.debugLyrics") {
            lines = Lyrics.parseLRC(Self.debugFixture)
            return
        }
        #endif
        guard let itemId, let client, let api else { return }
        isLoading = true
        let fetched = try? await client.serverLyrics(itemId: itemId, api: api)
        // A newer track may have started while this one was in flight.
        guard loadedKey == key else { return }
        lines = fetched
        isLoading = false
    }
}

#if DEBUG
extension LyricsModel {
    /// Karaoke lines every few seconds from 0:02, for -cascade.debugLyrics.
    static let debugFixture: String = {
        let lines = [
            "Every word of this line fills in as it is sung",
            "The next three lines wait below, fading into blur",
            "Past lines shrink above the current one",
            "Long lines like this one wrap across the width of the screen and keep filling word by word",
            "Scroll by hand to see all of them at once",
            "Then let go and it springs back to the current line",
            "Tap any line to jump to it",
            "One more line to keep the stack full",
            "And a last one to end on",
        ]
        func stamp(_ t: Double) -> String { String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        var t = 2.0
        return lines.map { line in
            let words = line.split(separator: " ")
            let step = 3.6 / Double(words.count)
            var out = "[\(stamp(t))]"
            for (i, w) in words.enumerated() { out += "<\(stamp(t + Double(i) * step))>\(w) " }
            t += 5
            return out
        }.joined(separator: "\n")
    }()
}
#endif

// The desktop's Now Playing lyrics (styles/np-overlay.css .ov-lyric-line,
// styles/karaoke.css, lyric-karaoke.js), carried over value for value:
// - the current line full white, the next three at 0.35 / 0.22 / 0.12 opacity
//   with 2 / 3 / 4 pt of blur, everything further out hidden at 0 opacity
//   and 6 pt blur;
// - past lines stay, unlike the desktop, which hides them: shrunk to 3/4
//   size at 0.3, so the song so far reads as context without competing;
// - those changes ease over 0.55 s on cubic-bezier(0.16, 1, 0.3, 1), and each
//   upcoming line starts 90 ms after the one before (up to three), so the
//   stack cascades instead of moving as one block;
// - the current line is moved into place by a spring of stiffness 250,
//   damping 50, and held high (12% down) as in Apple Music, not centred as
//   on the desktop;
// - karaoke words sit at 40% white and fill with white behind a soft edge
//   0.6 em wide, and a word the fill has reached lifts 0.04 em over 0.6 s;
// - scrolling by hand shows every line full size at 0.8 with a shadow, until the
//   scroll settles, then it springs back to the current line.
// The size differs too: the desktop's clamp(22px, 3vw, 50px) is sized for
// a window, and on a phone it would sit at its 22 px floor. Every value here
// is live in StyleTuning (the debug panel), under the defaults above.

/// The values live in StyleTuning, so the debug panel can move them; these
/// are the shapes that read them.
@MainActor
private enum LyricStyle {
    private static var v: StyleTuning.Values { StyleTuning.shared.values }
    static var size: CGFloat { v.lyricSize }
    static let weight: Font.Weight = .heavy          // 800
    static let tracking = -0.015                     // letter-spacing, in em
    static var lineGap: CGFloat { v.lineGap }        // padding: 12px, above and below
    static var unsung: Color { .white.opacity(v.unsungOpacity) }
    /// cubic-bezier(0.16, 1, 0.3, 1) over 0.55 s, the line fade and blur.
    static var fade: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: v.fadeSeconds) }
    static var ripple: Double { v.rippleSeconds }
    static let scroll = Animation.interpolatingSpring(stiffness: 250, damping: 50)
    /// Where the current line is held: a share of the lyrics area's height.
    static var anchor: UnitPoint { UnitPoint(x: 0, y: v.currentLinePosition) }
    /// The word lift: cubic-bezier(0.25, 0.8, 0.25, 1) over 0.6 s.
    static let lift = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.6)
    static var liftDistance: CGFloat { v.wordLift * size }
    /// Half of the fill's soft edge (0.3 em each side of its centre).
    static var edge: CGFloat { 0.3 * size }

    /// Opacity, blur and size (as a share of `size`) for a line `distance`
    /// from the current one.
    static func look(distance: Int, browsing: Bool) -> (opacity: Double, blur: CGFloat, scale: CGFloat) {
        if browsing { return (distance == 0 ? 1 : v.browsingOpacity, distance == 0 ? 0 : v.browsingBlur, 1) }
        switch distance {
        case ..<0: return (v.pastOpacity, v.pastBlur, v.pastScale)
        case 0: return (1, 0, 1)
        case 1: return (v.next1Opacity, v.next1Blur, 1)
        case 2: return (v.next2Opacity, v.next2Blur, 1)
        case 3: return (v.next3Opacity, v.next3Blur, 1)
        default: return (0, v.farBlur, 1)
        }
    }
}

/// Line-synced and karaoke lyrics, styled as on the desktop (see above). On
/// iOS a tapped line seeks to it.
struct LyricsView: View {
    let lines: [LyricLine]
    let player: PlaybackService

    /// The current line, from a clock of its own rather than the player's
    /// half-second position, so a line changes on its beat.
    @State private var active: Int?
    @State private var browsing = false
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            LyricLineView(line: lines[index],
                                          distance: Lyrics.lineDistance(index, active: active),
                                          browsing: browsing, player: player)
                                .id(index)
                                #if !os(tvOS)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await player.seek(to: Double(lines[index].start) / Double(Lyrics.ticksPerSecond)) }
                                }
                                #endif
                        }
                    }
                    // Room for the first and last lines to reach the current
                    // line's spot, wherever the tuning puts it.
                    .padding(.top, geo.size.height / 2)
                    .padding(.bottom, geo.size.height)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        settleTask?.cancel()
                        withAnimation(LyricStyle.fade) { browsing = true }
                    } else if phase == .idle, browsing {
                        settleTask?.cancel()
                        settleTask = Task {
                            try? await Task.sleep(for: .seconds(2.5))
                            guard !Task.isCancelled else { return }
                            withAnimation(LyricStyle.fade) { browsing = false }
                            withAnimation(LyricStyle.scroll) { proxy.scrollTo(active ?? 0, anchor: LyricStyle.anchor) }
                        }
                    }
                }
                .onChange(of: active) { _, index in
                    guard !browsing else { return }
                    withAnimation(LyricStyle.scroll) { proxy.scrollTo(index ?? 0, anchor: LyricStyle.anchor) }
                }
                .onAppear {
                    active = currentIndex()
                    proxy.scrollTo(active ?? 0, anchor: LyricStyle.anchor)
                }
            }
        }
        .task(id: lines.first?.start ?? -1) {
            // 20 Hz is ample for line changes; the active line's word fill
            // runs on its own per-frame timeline.
            while !Task.isCancelled {
                let index = currentIndex()
                if index != active { active = index }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func currentIndex() -> Int? {
        Lyrics.activeLineIndex(lines, at: Int(player.livePositionSeconds * Double(Lyrics.ticksPerSecond)))
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let distance: Int
    let browsing: Bool
    let player: PlaybackService

    var body: some View {
        let look = LyricStyle.look(distance: distance, browsing: browsing)
        let karaoke = !(line.words ?? []).isEmpty
        content(karaoke: karaoke)
            .modifier(LyricFont(scale: look.scale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, LyricStyle.lineGap * look.scale)
            // Browsing lines get a shadow to read over the blobs; karaoke words
            // do not, since their see-through fill showed it as a muddy outline.
            .shadow(color: .black.opacity(browsing && !karaoke ? 0.55 : 0), radius: 2, y: 1)
            .opacity(look.opacity)
            .blur(radius: look.blur)
            // Upcoming lines settle in one after another (the desktop's ripple).
            .animation(LyricStyle.fade.delay(distance > 0 ? Double(min(distance, 3)) * LyricStyle.ripple : 0),
                       value: distance)
            .animation(LyricStyle.fade, value: browsing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.text)
            .accessibilityAddTraits(distance == 0 ? .isSelected : [])
    }

    @ViewBuilder
    private func content(karaoke: Bool) -> some View {
        if karaoke, distance == 0, let words = line.words {
            // Only the current line redraws every frame.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: player.isPaused)) { _ in
                let now = Int(player.livePositionSeconds * Double(Lyrics.ticksPerSecond))
                WordFlow {
                    ForEach(words.indices, id: \.self) { i in
                        KaraokeWord(text: words[i].text, progress: Lyrics.wordProgress(words[i], at: now),
                                    sung: now >= words[i].start)
                    }
                }
            }
        } else if karaoke {
            Text(line.text).foregroundStyle(LyricStyle.unsung)
        } else {
            Text(line.text).foregroundStyle(.white)
        }
    }
}

/// The lyric font at a share of full size, animatable so a line shrinking into
/// the past resizes smoothly and rewraps as it goes. A scaleEffect would look
/// the same mid-line but keep the full-size height, leaving gaps above the
/// current line.
private struct LyricFont: ViewModifier, Animatable {
    var scale: CGFloat
    nonisolated var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: LyricStyle.size * scale, weight: LyricStyle.weight))
            .tracking(LyricStyle.tracking * LyricStyle.size * scale)
    }
}

/// One karaoke word: 40% white, filled with white up to its progress behind a
/// soft edge, lifted a little once the fill has reached it.
private struct KaraokeWord: View {
    let text: String
    let progress: Double
    let sung: Bool

    var body: some View {
        Text(text)
            .foregroundStyle(LyricStyle.unsung)
            .overlay {
                Text(text)
                    .foregroundStyle(.white)
                    .mask {
                        GeometryReader { geo in
                            // The edge's centre slides from 0.3 em before the
                            // word to 0.3 em past it, so an unsung word is fully
                            // dim and a sung one fully lit, never half an edge
                            // over either end (lyric-karaoke.js's --p).
                            let width = max(geo.size.width, 1)
                            let centre = progress * width + (progress * 2 - 1) * LyricStyle.edge
                            LinearGradient(stops: [
                                .init(color: .white, location: (centre - LyricStyle.edge) / width),
                                .init(color: .clear, location: (centre + LyricStyle.edge) / width),
                            ], startPoint: .leading, endPoint: .trailing)
                        }
                    }
            }
            .offset(y: sung ? -LyricStyle.liftDistance : 0)
            .animation(LyricStyle.lift, value: sung)
    }
}

/// Words laid out left to right, wrapping like text. A line of karaoke words
/// has to be one view per word for each to fill on its own, and SwiftUI's
/// stacks do not wrap.
private struct WordFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width
            }
            y += row.height
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
