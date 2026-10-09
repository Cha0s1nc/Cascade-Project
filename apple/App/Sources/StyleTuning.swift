import SwiftUI
import CascadeKit

/// Live knobs for the Now Playing look, the Swift side of the desktop's
/// cascadeDebug.lyricMotion: every lyric and background value that is a
/// matter of taste, read by LyricStyle and NowPlayingBackground, so a slider
/// shows its effect on the next frame. Saved between launches. The panel is
/// in every build, from Now Playing's ··· menu. The defaults are Jon's own
/// tuning from 2026-09-29 (Copy Changes, pasted back): quieter upcoming
/// lines, a slower fade, a faster ripple, and lyrics 0.35 s ahead. The
/// panel leads with presets for each group (StyleTuning.presetGroups), the
/// defaults being the middle one, and keeps every knob under Advanced.
@MainActor
@Observable
final class StyleTuning {
    static let shared = StyleTuning()

    struct Values: Equatable {
        #if os(tvOS)
        var lyricSize = 44.0
        #else
        var lyricSize = 30.0
        #endif
        /// Where the current line sits, as a share of the lyrics area's height
        /// from its top. Apple Music keeps it high, a line or so below the
        /// header, with only the last line or two showing above.
        var currentLinePosition = 0.12
        var lineGap = 8.0
        var pastScale = 0.75
        var pastOpacity = 0.3
        var pastBlur = 3.5
        var next1Opacity = 0.15
        var next1Blur = 2.5
        var next2Opacity = 0.11
        var next2Blur = 4.0
        var next3Opacity = 0.1
        var next3Blur = 4.0
        var farBlur = 6.0
        var browsingOpacity = 0.8
        var browsingBlur = 2.5
        var unsungOpacity = 0.29
        var wordLift = 0.04
        var fadeSeconds = 1.0
        var rippleSeconds = 0.04
        /// A held note swells across its own length, and more the longer it
        /// is: a note held this long or longer gets the full swell.
        var heldFullSeconds = 1.4
        /// The share of the full swell a note held just 1 s gets.
        var heldMinStrength = 0.45
        var heldLift = 0.16
        var heldScale = 1.19
        /// What is kept of the peak once the note ends, until the line does.
        var heldSettleSeconds = 0.4
        /// Lyrics drawn this much later than the audio clock (negative: earlier).
        /// A little early by default: a line takes its fade to light up, so
        /// one that starts on the beat reads as late. Apple Music leads too.
        var lyricsDelay = -0.05
        /// The scroll alone heads for the next line this many seconds early, so
        /// it is mostly there when the line lights. 0 scrolls with the highlight.
        var scrollLead = 0.0
        var backgroundVocalSize = 0.64
        var backgroundVocalOpacity = 0.85
        var bgSaturation = 1.0
        var bgBrightness = 0.0
        var bgIntensity = 1.0
        var bgSpeed = 1.0
        var bgBlur = 0.0
        /// Behind lyrics the background darkens by this much, plus up to
        /// lyricsDimBright more for a bright cover (Oklab lightness from
        /// lyricsDimFrom up to the palette's 0.82 ceiling), so the faint
        /// upcoming lines still read over a light salmon or yellow.
        var lyricsDimBase = 0.12
        var lyricsDimBright = 0.45
        var lyricsDimFrom = 0.5
        var controlsIdleSeconds = 4.0
        var controlsWokenIdleSeconds = 8.0
    }

    struct Knob {
        let section: String
        let label: String
        let path: WritableKeyPath<Values, Double>
        let range: ClosedRange<Double>
        let step: Double
        /// Saved under this; also the name in "Copy Changes".
        let key: String
    }

    static let knobs: [Knob] = [
        Knob(section: "Lyrics layout", label: "Lyrics timing (s)", path: \.lyricsDelay, range: -2...2, step: 0.05, key: "lyricsDelay"),
        Knob(section: "Lyrics layout", label: "Scroll ahead (s)", path: \.scrollLead, range: 0...1, step: 0.05, key: "scrollLead"),
        Knob(section: "Lyrics layout", label: "Text size", path: \.lyricSize, range: 18...60, step: 1, key: "lyricSize"),
        Knob(section: "Lyrics layout", label: "Current line position", path: \.currentLinePosition, range: 0...0.6, step: 0.01, key: "currentLinePosition"),
        Knob(section: "Lyrics layout", label: "Line gap", path: \.lineGap, range: 0...40, step: 1, key: "lineGap"),
        Knob(section: "Past lines", label: "Size", path: \.pastScale, range: 0.4...1, step: 0.01, key: "pastScale"),
        Knob(section: "Past lines", label: "Opacity", path: \.pastOpacity, range: 0...1, step: 0.01, key: "pastOpacity"),
        Knob(section: "Past lines", label: "Blur", path: \.pastBlur, range: 0...8, step: 0.5, key: "pastBlur"),
        Knob(section: "Upcoming lines", label: "Next opacity", path: \.next1Opacity, range: 0...1, step: 0.01, key: "next1Opacity"),
        Knob(section: "Upcoming lines", label: "Next blur", path: \.next1Blur, range: 0...8, step: 0.5, key: "next1Blur"),
        Knob(section: "Upcoming lines", label: "Second opacity", path: \.next2Opacity, range: 0...1, step: 0.01, key: "next2Opacity"),
        Knob(section: "Upcoming lines", label: "Second blur", path: \.next2Blur, range: 0...8, step: 0.5, key: "next2Blur"),
        Knob(section: "Upcoming lines", label: "Third opacity", path: \.next3Opacity, range: 0...1, step: 0.01, key: "next3Opacity"),
        Knob(section: "Upcoming lines", label: "Third blur", path: \.next3Blur, range: 0...8, step: 0.5, key: "next3Blur"),
        Knob(section: "Upcoming lines", label: "Blur further out", path: \.farBlur, range: 0...12, step: 0.5, key: "farBlur"),
        Knob(section: "Upcoming lines", label: "Blur while scrolling", path: \.browsingBlur, range: 0...8, step: 0.5, key: "browsingBlur"),
        Knob(section: "Upcoming lines", label: "Opacity while scrolling", path: \.browsingOpacity, range: 0...1, step: 0.01, key: "browsingOpacity"),
        Knob(section: "Karaoke", label: "Unsung word opacity", path: \.unsungOpacity, range: 0...1, step: 0.01, key: "unsungOpacity"),
        Knob(section: "Karaoke", label: "Word lift (em)", path: \.wordLift, range: 0...0.2, step: 0.005, key: "wordLift"),
        Knob(section: "Karaoke", label: "Held note: full swell after (s)", path: \.heldFullSeconds, range: 1...8, step: 0.1, key: "heldFullSeconds"),
        Knob(section: "Karaoke", label: "Held note: short note strength", path: \.heldMinStrength, range: 0...1, step: 0.05, key: "heldMinStrength"),
        Knob(section: "Karaoke", label: "Held note lift (em)", path: \.heldLift, range: 0...0.4, step: 0.01, key: "heldLift"),
        Knob(section: "Karaoke", label: "Held note swell", path: \.heldScale, range: 1...1.4, step: 0.01, key: "heldScale"),
        Knob(section: "Karaoke", label: "Held note release time (s)", path: \.heldSettleSeconds, range: 0...2, step: 0.05, key: "heldSettleSeconds"),
        Knob(section: "Karaoke", label: "Background vocal size", path: \.backgroundVocalSize, range: 0.4...1, step: 0.01, key: "backgroundVocalSize"),
        Knob(section: "Karaoke", label: "Background vocal opacity", path: \.backgroundVocalOpacity, range: 0...1, step: 0.01, key: "backgroundVocalOpacity"),
        Knob(section: "Motion", label: "Line fade (s)", path: \.fadeSeconds, range: 0...2, step: 0.05, key: "fadeSeconds"),
        Knob(section: "Motion", label: "Ripple per line (s)", path: \.rippleSeconds, range: 0...0.4, step: 0.01, key: "rippleSeconds"),
        Knob(section: "Background colors", label: "Saturation", path: \.bgSaturation, range: 0...2, step: 0.05, key: "bgSaturation"),
        Knob(section: "Background colors", label: "Brightness", path: \.bgBrightness, range: -0.5...0.5, step: 0.01, key: "bgBrightness"),
        Knob(section: "Background colors", label: "Intensity", path: \.bgIntensity, range: 0...2, step: 0.05, key: "bgIntensity"),
        Knob(section: "Background colors", label: "Drift speed", path: \.bgSpeed, range: 0...5, step: 0.1, key: "bgSpeed"),
        Knob(section: "Background colors", label: "Blur", path: \.bgBlur, range: 0...80, step: 1, key: "bgBlur"),
        Knob(section: "Background colors", label: "Dim behind lyrics", path: \.lyricsDimBase, range: 0...0.8, step: 0.01, key: "lyricsDimBase"),
        Knob(section: "Background colors", label: "Extra dim for bright covers", path: \.lyricsDimBright, range: 0...0.8, step: 0.01, key: "lyricsDimBright"),
        Knob(section: "Background colors", label: "Counts as bright from", path: \.lyricsDimFrom, range: 0.3...0.82, step: 0.01, key: "lyricsDimFrom"),
        Knob(section: "Controls", label: "Hide after (s)", path: \.controlsIdleSeconds, range: 1...20, step: 0.5, key: "controlsIdleSeconds"),
        Knob(section: "Controls", label: "Hide after a touch (s)", path: \.controlsWokenIdleSeconds, range: 1...30, step: 0.5, key: "controlsWokenIdleSeconds"),
    ]

    /// A named set of values for some of the knobs.
    struct Preset: Identifiable {
        let name: String
        let settings: [WritableKeyPath<Values, Double>: Double]
        var id: String { name }

        /// The shipped values for these knobs, so the default preset can
        /// never drift from the defaults.
        static func standard(_ name: String, _ keys: [WritableKeyPath<Values, Double>]) -> Preset {
            let v = Values()
            return Preset(name: name, settings: Dictionary(uniqueKeysWithValues: keys.map { ($0, v[keyPath: $0]) }))
        }
    }

    /// The panel's first page: a few knobs at a time as three choices, the
    /// shipped look in the middle, rather than thirty sliders.
    struct PresetGroup: Identifiable {
        let title: String
        let footer: String
        let presets: [Preset]
        var id: String { title }
    }

    static let presetGroups: [PresetGroup] = [
        PresetGroup(title: "Lines Around the Current One",
                    footer: "How much of the song shows above and below the line being sung.",
                    presets: [
                        Preset(name: "Minimal", settings: [\.next1Opacity: 0.08, \.next1Blur: 3, \.next2Opacity: 0.05, \.next2Blur: 5,
                                                           \.next3Opacity: 0, \.next3Blur: 6, \.pastOpacity: 0.18, \.pastBlur: 5]),
                        .standard("Focused", [\.next1Opacity, \.next1Blur, \.next2Opacity, \.next2Blur,
                                              \.next3Opacity, \.next3Blur, \.pastOpacity, \.pastBlur]),
                        Preset(name: "Open", settings: [\.next1Opacity: 0.35, \.next1Blur: 2, \.next2Opacity: 0.22, \.next2Blur: 3,
                                                        \.next3Opacity: 0.12, \.next3Blur: 4, \.pastOpacity: 0.4, \.pastBlur: 1]),
                    ]),
        PresetGroup(title: "Motion",
                    footer: "How lines fade and move as the song goes on.",
                    presets: [
                        Preset(name: "Snappy", settings: [\.fadeSeconds: 0.35, \.rippleSeconds: 0.02]),
                        .standard("Smooth", [\.fadeSeconds, \.rippleSeconds]),
                        Preset(name: "Floaty", settings: [\.fadeSeconds: 1.6, \.rippleSeconds: 0.12]),
                    ]),
        PresetGroup(title: "Held Notes",
                    footer: "How much a long, held note swells and glows. Spicy Lyrics only.",
                    presets: [
                        Preset(name: "Subtle", settings: [\.heldLift: 0.05, \.heldScale: 1.04, \.heldMinStrength: 0.2]),
                        .standard("Expressive", [\.heldLift, \.heldScale, \.heldMinStrength]),
                        Preset(name: "Dramatic", settings: [\.heldLift: 0.18, \.heldScale: 1.15, \.heldMinStrength: 0.45]),
                    ]),
        PresetGroup(title: "Background",
                    footer: "The cover's colors behind the player, and how far they darken under lyrics.",
                    presets: [
                        Preset(name: "Vivid", settings: [\.bgSaturation: 1.2, \.bgIntensity: 1.1, \.lyricsDimBase: 0.05, \.lyricsDimBright: 0.3]),
                        .standard("Balanced", [\.bgSaturation, \.bgIntensity, \.lyricsDimBase, \.lyricsDimBright]),
                        Preset(name: "Muted", settings: [\.bgSaturation: 0.7, \.bgIntensity: 0.8, \.lyricsDimBase: 0.25, \.lyricsDimBright: 0.5]),
                    ]),
    ]

    /// The preset a group's knobs match now, or nil when they are custom.
    func preset(in group: PresetGroup) -> Preset? {
        group.presets.first { $0.settings.allSatisfy { abs(values[keyPath: $0.key] - $0.value) < 0.0005 } }
    }

    func apply(_ preset: Preset) {
        var v = values
        for (path, value) in preset.settings { v[keyPath: path] = value }
        values = v
    }

    private static let storeKey = "cascade.styleTuning"

    var values: Values { didSet { if !layering { save() } } }

    /// The server's lyrics look (CascadeKit's ServerStyle), layered over the
    /// stored changes by applyServerStyle and never saved into them.
    private(set) var serverStyle = ServerStyle.off
    @ObservationIgnored private var layering = false
    var lyricsLocked: Bool { serverStyle.lyricsPart == .force }

    func applyServerStyle(_ style: ServerStyle) {
        serverStyle = style
        var layered = style.layeredLyricChanges(UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: Double] ?? [:])
        #if os(macOS)
        // The desktop sizes lyrics by lyricScale, here the lyricSize knob
        // (LookPresets: 1 is 30 pt).
        if let scale = style.preset?.lyrics?.lyricScale,
           style.lyricsPart == .force || (style.lyricsPart == .fill && layered["lyricSize"] == nil) {
            layered["lyricSize"] = scale * 30
        }
        #endif
        var v = Values()
        for knob in Self.knobs {
            // Clamped here: the server's numbers come from someone else's preset.
            if let x = layered[knob.key] { v[keyPath: knob.path] = min(max(x, knob.range.lowerBound), knob.range.upperBound) }
        }
        layering = true
        values = v
        layering = false
    }

    private init() {
        var v = Values()
        let saved = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: Double] ?? [:]
        for knob in Self.knobs {
            if let x = saved[knob.key] { v[keyPath: knob.path] = x }
        }
        values = v
    }

    /// Only what differs from the defaults, so a changed default still
    /// reaches anyone who never touched that knob.
    var changes: [String: Double] {
        let defaults = Values()
        return Dictionary(uniqueKeysWithValues: Self.knobs.compactMap { knob in
            values[keyPath: knob.path] == defaults[keyPath: knob.path] ? nil : (knob.key, values[keyPath: knob.path])
        })
    }

    private func save() {
        UserDefaults.standard.set(changes, forKey: Self.storeKey)
    }

    // MARK: New defaults

    /// Bumped each time the shipped defaults are re-baked, with the knobs that
    /// moved. Someone who never touched those knobs gets the new values by
    /// themselves (only changes are stored); someone who did is asked, once,
    /// whether to take the new ones. Revision 2: the stable build's own tuning
    /// (2026-10-06). A new bake adds the next number and its knobs here.
    static let defaultsRevision = 2
    static let knobsChanged: [Int: [String]] = [
        2: ["browsingBlur", "unsungOpacity", "heldFullSeconds", "heldMinStrength", "heldLift",
            "heldScale", "heldSettleSeconds", "lyricsDelay"],
    ]
    private static let defaultsSeenKey = "cascade.styleTuningDefaultsSeen"

    /// The re-baked knobs this person set themselves since the defaults they
    /// last saw, so the new values do not reach them unasked. Empty: nothing
    /// to ask, and `markDefaultsSeen` can be called quietly.
    var knobsWithNewDefaults: [Knob] {
        let seen = UserDefaults.standard.object(forKey: Self.defaultsSeenKey) as? Int ?? 1
        guard seen < Self.defaultsRevision else { return [] }
        let moved = Set((seen + 1...Self.defaultsRevision).flatMap { Self.knobsChanged[$0] ?? [] })
        let mine = changes
        return Self.knobs.filter { moved.contains($0.key) && mine[$0.key] != nil }
    }

    /// Puts those knobs back to the new defaults; the rest of the tuning stays.
    func applyNewDefaults() {
        let defaults = Values()
        var v = values
        for knob in knobsWithNewDefaults { v[keyPath: knob.path] = defaults[keyPath: knob.path] }
        values = v
        markDefaultsSeen()
    }

    func markDefaultsSeen() {
        UserDefaults.standard.set(Self.defaultsRevision, forKey: Self.defaultsSeenKey)
    }
}

extension View {
    /// Asks once, when Now Playing opens, whether to take re-baked lyric
    /// defaults over the knobs this person tuned themselves.
    func newLyricDefaultsPrompt() -> some View { modifier(NewLyricDefaultsPrompt()) }
}

private struct NewLyricDefaultsPrompt: ViewModifier {
    @State private var knobs: [StyleTuning.Knob] = []
    @State private var asking = false

    func body(content: Content) -> some View {
        content
            .task {
                let pending = StyleTuning.shared.knobsWithNewDefaults
                if pending.isEmpty { StyleTuning.shared.markDefaultsSeen(); return }
                // A beat after opening, so it does not land on the transition.
                try? await Task.sleep(for: .milliseconds(600))
                knobs = pending
                asking = true
            }
            .alert("New lyric defaults", isPresented: $asking) {
                Button("Use the New Defaults") { StyleTuning.shared.applyNewDefaults() }
                Button("Keep Mine", role: .cancel) { StyleTuning.shared.markDefaultsSeen() }
            } message: {
                Text("Cascade's lyric look was retuned. You changed \(knobs.count == 1 ? "one of these settings" : "\(knobs.count) of these settings") yourself: \(knobs.map(\.label).joined(separator: ", ")). Use the new defaults for them, or keep yours?")
            }
    }
}

#if os(iOS)
/// The tuning panel, from Now Playing's ··· menu: text size and timing, a
/// preset per group, and every knob under Advanced. A short sheet the player
/// stays live behind, so each change shows as it is made.
struct StyleTuningSheet: View {
    @Bindable private var tuning = StyleTuning.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(["lyricSize", "lyricsDelay"], id: \.self) { key in
                        if let knob = StyleTuning.knobs.first(where: { $0.key == key }) { KnobRow(knob: knob) }
                    }
                } footer: {
                    Text("Negative timing shows lyrics earlier. Double-tap a slider to put it back.")
                }
                ForEach(StyleTuning.presetGroups) { group in
                    Section {
                        presetPicker(group)
                    } header: {
                        Text(group.title)
                    } footer: {
                        Text(group.footer)
                    }
                }
                Section {
                    NavigationLink("Advanced") { StyleTuningAdvanced() }
                } footer: {
                    Text("Every setting on its own, including past lines, karaoke words and when the controls hide.")
                }
            }
            .navigationTitle("Style Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { tuning.values = .init() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Paste this back to bake a tuning in as the defaults.
                        Button("Copy Changes", systemImage: "doc.on.doc") {
                            let lines = tuning.changes.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
                            UIPasteboard.general.string = lines.isEmpty ? "(all defaults)" : lines.joined(separator: "\n")
                        }
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.35), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    /// The group's three choices, plus Custom while its knobs match none
    /// (only shown then: picking it would mean nothing).
    private func presetPicker(_ group: StyleTuning.PresetGroup) -> some View {
        let current = tuning.preset(in: group)?.name ?? "Custom"
        return Picker(group.title, selection: Binding(
            get: { current },
            set: { name in
                if let preset = group.presets.first(where: { $0.name == name }) { tuning.apply(preset) }
            })) {
            ForEach(group.presets) { Text($0.name).tag($0.name) }
            if current == "Custom" { Text("Custom").tag("Custom") }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Every knob, by section.
private struct StyleTuningAdvanced: View {
    private var sections: [String] {
        StyleTuning.knobs.map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        Form {
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(StyleTuning.knobs.filter { $0.section == section }, id: \.key) { KnobRow(knob: $0) }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One knob: its value (orange once changed) over a slider. Double-tap puts
/// it back to the default.
private struct KnobRow: View {
    let knob: StyleTuning.Knob
    @Bindable private var tuning = StyleTuning.shared

    var body: some View {
        let value = tuning.values[keyPath: knob.path]
        let changed = value != StyleTuning.Values()[keyPath: knob.path]
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(knob.label)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(knob.step < 0.01 ? 3 : knob.step < 1 ? 2 : 0)))
                    .monospacedDigit()
                    .foregroundStyle(changed ? .orange : .secondary)
            }
            .font(.subheadline)
            Slider(value: $tuning.values[dynamicMember: knob.path], in: knob.range, step: knob.step)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tuning.values[keyPath: knob.path] = StyleTuning.Values()[keyPath: knob.path] }
    }
}
#endif
