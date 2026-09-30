import SwiftUI
import CascadeKit

/// Loads the current track's lyrics for the Now Playing screen, from Cascade
/// Server alone or the whole waterfall (LyricsWaterfall). Views read
/// `lines`: nil while loading or when the track has none, which `isLoading`
/// and `instrumental` tell apart. `credit` is set when they came from
/// SpicyLyrics, whose terms want it on screen with them.
@MainActor
@Observable
final class LyricsModel {
    private(set) var lines: [LyricLine]?
    private(set) var credit: SpicyCredit?
    /// False for untimed lyrics, drawn as a still page.
    private(set) var synced = true
    private(set) var instrumental = false
    /// True from a track change until its lyrics are in (or known missing).
    /// Without it, the brief nil between two tracks read as "this song has no
    /// lyrics", and Now Playing left lyrics mode on every skip.
    private(set) var isLoading = false
    /// What was asked for last: the track and everything that changes the
    /// answer (the plugin, server-only, a Spotify link).
    private var loadedKey: String?

    /// Answers this session, misses included, keyed as loadedKey. The sheet
    /// is rebuilt on every opening, and without this each one asked all four
    /// sources again; a miss is kept too, or an instrumental album re-ran the
    /// whole waterfall on every track, as the desktop once did.
    private static var cache: [String: LyricsResult?] = [:]

    func load(item: JfItem?, state: AppState) async {
        let plugin = state.cascadePluginApi.map { (api: $0, info: state.cascadePluginInfo) }
        let spotifyId = item.flatMap { state.localSpotifyLinks[$0.id] }
        let key = [item?.id ?? "", String(describing: plugin?.api), "\(plugin?.info.capabilities.sorted() ?? [])",
                   "\(state.serverOnlyLyrics)", spotifyId ?? "", "\(state.lyricsRevision)"].joined(separator: "|")
        guard key != loadedKey else { return }
        show(nil)
        loadedKey = key
        #if DEBUG
        // Launch with -cascade.debugLyrics YES (Enhanced LRC) or
        // -cascade.debugSpicy YES (a SpicyLyrics reply, through the real
        // converter) to style-check lyrics against a server with no Cascade
        // plugin (the local test server has none).
        if UserDefaults.standard.bool(forKey: "cascade.debugSpicy"), let conv = SpicyLyrics.convert(Self.debugSpicyFixture) {
            show(LyricsResult(lines: conv.lines, credit: conv.credit, source: conv.credit.provider))
            return
        }
        if UserDefaults.standard.bool(forKey: "cascade.debugLyrics") {
            show(LyricsResult(lines: Lyrics.parseLRC(Self.debugFixture), source: "Debug"))
            return
        }
        #endif
        guard let item, let client = state.client else { return }
        if let hit = Self.cache[key] {
            show(hit)
            return
        }
        isLoading = true
        let track = LyricsWaterfall.Track(id: item.id, title: item.name ?? "",
                                          artist: item.albumArtist ?? item.artists?.first ?? "", album: item.album ?? "",
                                          durationSeconds: Double(item.runTimeTicks ?? 0) / Double(Lyrics.ticksPerSecond))
        let result = await LyricsWaterfall.fetch(track, client: client, plugin: plugin,
                                                 serverOnly: state.serverOnlyLyrics, spotifyId: spotifyId,
                                                 userAgent: "Cascade/\(state.appVersion) (iOS; Jellyfin music client)")
        Self.cache[key] = result
        // A newer track may have started while this one was in flight.
        guard loadedKey == key else { return }
        show(result)
    }

    private func show(_ result: LyricsResult?) {
        lines = result.flatMap { $0.lines.isEmpty ? nil : $0.lines }
        credit = result?.credit
        synced = result?.synced ?? true
        instrumental = result?.instrumental ?? false
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

    /// A SpicyLyrics community sync, 4 s a line from 0:02: a word held over
    /// two syllables, a duet's second voice, background vocals under both
    /// voices, a long held "oh", and an uploader and maker to credit.
    static let debugSpicyFixture: [String: Any] = {
        func syl(_ text: String, _ start: Double, _ end: Double, joined: Bool = false) -> [String: Any] {
            ["Text": text, "StartTime": start, "EndTime": end, "IsPartOfWord": joined]
        }
        func line(_ syls: [[String: Any]], opposite: Bool = false, background: [[String: Any]]? = nil) -> [String: Any] {
            var out: [String: Any] = ["Type": "Vocal", "OppositeAligned": opposite,
                                      "Lead": ["StartTime": syls.first!["StartTime"]!, "EndTime": syls.last!["EndTime"]!,
                                               "Syllables": syls]]
            if let background { out["Background"] = [["Syllables": background]] }
            return out
        }
        return ["Type": "Syllable", "source": "spicy_lyrics", "EndTime": 26.0,
                "UploadAttribution": ["Uploader": ["username": "cascade-debug", "url": "https://example.com/uploader"],
                                      "Maker": ["username": "fixture-maker"]],
                "Content": [
                    line([syl("Wait", 2, 2.4), syl("for", 2.4, 2.7), syl("it,", 2.7, 3.0), syl("hold", 3.0, 3.3),
                          syl("the", 3.3, 3.5), syl("wai", 3.5, 3.8, joined: true), syl("ting", 3.8, 5.6)]),
                    line([syl("The", 6, 6.3), syl("second", 6.3, 6.8), syl("voice", 6.8, 7.2), syl("answers", 7.2, 7.8),
                          syl("from", 7.8, 8.1), syl("the", 8.1, 8.3), syl("right", 8.3, 9.2)], opposite: true),
                    line([syl("Back", 10, 10.4), syl("to", 10.4, 10.6), syl("the", 10.6, 10.8), syl("lead", 10.8, 11.3),
                          syl("with", 11.3, 11.6), syl("an", 11.6, 11.8), syl("echo", 11.8, 12.6)],
                         background: [syl("(echo,", 11.2, 11.9), syl("echo)", 12.0, 12.8)]),
                    line([syl("Both", 14, 14.4), syl("sides", 14.4, 14.9), syl("answer", 14.9, 15.6), syl("back", 15.6, 16.2)],
                         opposite: true, background: [syl("(back", 15.0, 15.6), syl("again)", 15.6, 16.4)]),
                    line([syl("And", 18, 18.3), syl("one", 18.3, 18.6), syl("long", 18.6, 19.0), syl("held", 19.0, 19.4),
                          syl("oh", 19.4, 22.0)]),
                    line([syl("Then", 22, 22.4), syl("a", 22.4, 22.5), syl("quiet", 22.5, 23.1), syl("close", 23.1, 24.0)]),
                ]]
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

    /// The lyric clock: the audio's position less the user's lyrics delay.
    static func nowTicks(_ player: PlaybackService) -> Int {
        Int((player.livePositionSeconds - v.lyricsDelay) * Double(Lyrics.ticksPerSecond))
    }

    static var heldLift: CGFloat { v.heldLift * size }
    static var heldScale: CGFloat { v.heldScale }
    static var backgroundSize: CGFloat { v.backgroundVocalSize * size }
    static var backgroundOpacity: Double { v.backgroundVocalOpacity }

    /// How swollen a held note's letter is, 0 to 1 of the full swell.
    ///
    /// Apple Music swells a held note more the longer it is: a short hold
    /// barely, a long one slowly more and more until it ends. So the swell's
    /// strength comes from the note's length (a 1 s hold gets
    /// heldMinStrength, heldFullSeconds or longer gets it all), and each
    /// letter rises from when the fill reaches it until the note ends, then
    /// settles to heldSettle of its peak until the line changes. A letter
    /// reached near the end still rises over at least 0.35 s rather than
    /// popping. Tunable live; a guess at the curve until it is measured
    /// against a recording, as the desktop's fixed 1.7 s swell was.
    static func swell(sinceLit: Double, untilEnd: Double, held: Double) -> Double {
        guard sinceLit >= 0 else { return 0 }
        let reach = v.heldFullSeconds > 1 ? min(1, max(0, (held - 1) / (v.heldFullSeconds - 1))) : 1
        let strength = v.heldMinStrength + (1 - v.heldMinStrength) * reach
        let rise = max(untilEnd, 0.35)
        if sinceLit < rise { return strength * UnitCurve.easeInOut.value(at: sinceLit / rise) }
        let settle = v.heldSettleSeconds > 0 ? min(1, (sinceLit - rise) / v.heldSettleSeconds) : 1
        return strength * (1 - (1 - v.heldSettle) * UnitCurve.easeInOut.value(at: settle))
    }

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
    /// Held notes swell: only for SpicyLyrics, whose syllables carry real end
    /// times (see Lyrics.isEmphasisWord).
    var emphasis = false
    /// False for lyrics with no timings: a still page to scroll, every line
    /// lit, with nothing to follow.
    var synced = true

    /// The current line, from a clock of its own rather than the player's
    /// half-second position, so a line changes on its beat.
    @State private var active: Int?
    @State private var browsing = false
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        if synced { syncedBody } else { stillPage }
    }

    private var stillPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index].text)
                        .font(.system(size: LyricStyle.size, weight: LyricStyle.weight))
                        .tracking(LyricStyle.tracking * LyricStyle.size)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, LyricStyle.lineGap)
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var syncedBody: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { index in
                            LyricLineView(line: lines[index],
                                          distance: Lyrics.lineDistance(index, active: active),
                                          browsing: browsing, emphasis: emphasis, player: player)
                                .id(index)
                                #if !os(tvOS)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let start = Double(lines[index].start) / Double(Lyrics.ticksPerSecond)
                                    Task { await player.seek(to: start + StyleTuning.shared.values.lyricsDelay) }
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
                    // Again after the first layout: the scroll above can land
                    // before the lines have sizes, and while paused nothing
                    // moves them again, which left the current line low.
                    DispatchQueue.main.async { proxy.scrollTo(active ?? 0, anchor: LyricStyle.anchor) }
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
        Lyrics.activeLineIndex(lines, at: LyricStyle.nowTicks(player))
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    let distance: Int
    let browsing: Bool
    let emphasis: Bool
    let player: PlaybackService

    var body: some View {
        let look = LyricStyle.look(distance: distance, browsing: browsing)
        let karaoke = !(line.words ?? []).isEmpty
        // A duet's second voice sits on the right, background row with it.
        let side: Alignment = line.opposite ? .trailing : .leading
        ShrinkWithoutRewrap(scale: look.scale) {
            content(karaoke: karaoke)
                .font(.system(size: LyricStyle.size, weight: LyricStyle.weight))
                .tracking(LyricStyle.tracking * LyricStyle.size)
                .frame(maxWidth: .infinity, alignment: side)
                .scaleEffect(look.scale, anchor: line.opposite ? .topTrailing : .topLeading)
        }
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
        if karaoke, let words = line.words {
            // Every karaoke line is laid out word by word, current or not, so
            // it wraps the same way throughout. Drawn as one Text while
            // waiting and as words once current, a line could rewrap the
            // moment it became current. Only the current line's timeline
            // runs; the rest sit unsung, as on the desktop.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: distance != 0 || player.isPaused)) { _ in
                let now = distance == 0 ? LyricStyle.nowTicks(player) : Int.min
                VStack(alignment: line.opposite ? .trailing : .leading, spacing: 0) {
                    wordFlow(words, now: now)
                    if let background = line.background {
                        // Background vocals: a smaller, quieter row that opens
                        // under the line while it is current and closes after,
                        // as in Apple Music (karaoke.css .lyric-bg).
                        ShrinkWithoutRewrap(scale: distance == 0 ? 1 : 0) {
                            wordFlow(background, now: now)
                                .font(.system(size: LyricStyle.backgroundSize, weight: .semibold))
                                .tracking(LyricStyle.tracking * LyricStyle.backgroundSize)
                                .padding(.top, 0.3 * LyricStyle.backgroundSize)
                        }
                        .clipped()
                        .opacity(distance == 0 ? LyricStyle.backgroundOpacity : 0)
                        .animation(.easeInOut(duration: 0.4), value: distance == 0)
                    }
                }
            }
        } else {
            // Right alignment only here: on a karaoke word it drew the letters
            // flush right with the word's trailing space in front of them
            // ("theright"). WordFlow right-aligns karaoke rows itself.
            Text(line.text)
                .foregroundStyle(.white)
                .multilineTextAlignment(line.opposite ? .trailing : .leading)
        }
    }

    /// Words in their layout units (Lyrics.wordUnits): a unit never wraps
    /// inside itself, and a held note swells letter by letter.
    private func wordFlow(_ words: [LyricWord], now: Int) -> some View {
        let units = Lyrics.wordUnits(words, emphasis: emphasis)
        return WordFlow(trailing: line.opposite) {
            ForEach(units.indices, id: \.self) { u in
                HStack(spacing: 0) {
                    ForEach(units[u].indices, id: \.self) { i in
                        let word = units[u][i]
                        if emphasis, Lyrics.isEmphasisWord(word) {
                            HeldWord(word: word, now: now, standalone: units[u].count == 1)
                        } else {
                            KaraokeWord(text: word.text, progress: Lyrics.wordProgress(word, at: now),
                                        sung: now >= word.start)
                        }
                    }
                }
            }
        }
    }
}

/// Shrinks a line as a picture rather than re-laying it out: the text wraps
/// exactly as at full size, and only its height follows the shrink, so no gap
/// opens around a past line. Resizing the font instead rewrapped lines as they
/// moved into the past, which read as jitter. Also opens and closes the
/// background vocal row: content drawn unscaled, clipped to a share of its
/// height.
private struct ShrinkWithoutRewrap: Layout {
    var scale: CGFloat
    nonisolated var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
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

/// A held note, letter by letter as Apple Music draws it: the fill sweeps the
/// letters in turn, and each one rises, swells and glows from when the fill
/// reaches it (LyricStyle.swell). Held notes skip the ordinary word lift;
/// their letters do their own, larger one.
private struct HeldWord: View {
    let word: LyricWord
    let now: Int
    /// On its own rather than one syllable of a word: gets room each side to
    /// swell into, so it never overlaps its neighbours.
    let standalone: Bool

    var body: some View {
        let tps = Double(Lyrics.ticksPerSecond)
        let letters = Array(word.text.trimmingCharacters(in: .whitespaces))
        let n = Double(max(letters.count, 1))
        let progress = Lyrics.wordProgress(word, at: now)
        let start = Double(word.start) / tps
        let held = Double((word.end ?? word.start) - word.start) / tps
        let seconds = Double(now) / tps
        HStack(spacing: 0) {
            ForEach(letters.indices, id: \.self) { i in
                let litAt = start + held * Double(i) / n
                let s = now == Int.min ? 0 : LyricStyle.swell(sinceLit: seconds - litAt, untilEnd: start + held - litAt, held: held)
                KaraokeWord(text: String(letters[i]), progress: min(1, max(0, progress * n - Double(i))), sung: false)
                    .shadow(color: .white.opacity(0.7 * s), radius: 0.35 * LyricStyle.size * s)
                    .scaleEffect(1 + (LyricStyle.heldScale - 1) * s, anchor: UnitPoint(x: 0.5, y: 0.75))
                    .offset(y: -LyricStyle.heldLift * s)
            }
            if word.text.last?.isWhitespace == true { Text(" ") }
        }
        .padding(.horizontal, standalone ? 0.06 * LyricStyle.size : 0)
    }
}

/// Credit for SpicyLyrics lyrics, which their terms want on screen wherever
/// they show: the provider, then the uploader and maker of a community sync.
/// Names link to their https pages on iOS.
struct LyricsCreditView: View {
    let credit: SpicyCredit

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
            .tint(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: AttributedString {
        var out = AttributedString(credit.provider)
        for (role, person) in [("Uploaded by", credit.uploader), ("Synced by", credit.maker)] {
            guard let person else { continue }
            out += AttributedString(" · \(role) ")
            var name = AttributedString(person.name)
            #if os(iOS)
            name.link = person.url
            #endif
            out += name
        }
        return out
    }
}

/// Words laid out left to right, wrapping like text. A line of karaoke words
/// has to be one view per word for each to fill on its own, and SwiftUI's
/// stacks do not wrap.
private struct WordFlow: Layout {
    /// Rows flush right, for a duet's second voice.
    var trailing = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = trailing ? bounds.maxX - row.width : bounds.minX
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
