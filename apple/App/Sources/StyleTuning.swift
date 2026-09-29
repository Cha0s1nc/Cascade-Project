import SwiftUI

/// Live knobs for the Now Playing look, the Swift side of the desktop's
/// cascadeDebug.lyricMotion: every lyric and background value that is a
/// matter of taste, read by LyricStyle and NowPlayingBackground, so a slider
/// shows its effect on the next frame. Saved between launches. The panel is
/// DEBUG only; the values are read in every build, so a tuning worth keeping
/// is baked in by making it the default here.
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
        var lineGap = 12.0
        var pastScale = 0.75
        var pastOpacity = 0.3
        var pastBlur = 0.0
        var next1Opacity = 0.35
        var next1Blur = 2.0
        var next2Opacity = 0.22
        var next2Blur = 3.0
        var next3Opacity = 0.12
        var next3Blur = 4.0
        var farBlur = 6.0
        var browsingOpacity = 0.8
        var browsingBlur = 0.0
        var unsungOpacity = 0.4
        var wordLift = 0.04
        var fadeSeconds = 0.55
        var rippleSeconds = 0.09
        var heldRiseSeconds = 1.7
        var heldLift = 0.1
        var heldScale = 1.08
        var heldSettle = 0.6
        var backgroundVocalSize = 0.64
        var backgroundVocalOpacity = 0.85
        var bgSaturation = 1.0
        var bgBrightness = 0.0
        var bgIntensity = 1.0
        var bgSpeed = 1.0
        var bgBlur = 0.0
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
        Knob(section: "Upcoming lines", label: "Further out blur", path: \.farBlur, range: 0...12, step: 0.5, key: "farBlur"),
        Knob(section: "Upcoming lines", label: "Browsing blur", path: \.browsingBlur, range: 0...8, step: 0.5, key: "browsingBlur"),
        Knob(section: "Upcoming lines", label: "Browsing opacity", path: \.browsingOpacity, range: 0...1, step: 0.01, key: "browsingOpacity"),
        Knob(section: "Karaoke", label: "Unsung word opacity", path: \.unsungOpacity, range: 0...1, step: 0.01, key: "unsungOpacity"),
        Knob(section: "Karaoke", label: "Word lift (em)", path: \.wordLift, range: 0...0.2, step: 0.005, key: "wordLift"),
        Knob(section: "Karaoke", label: "Held note rise (s)", path: \.heldRiseSeconds, range: 0.3...4, step: 0.05, key: "heldRiseSeconds"),
        Knob(section: "Karaoke", label: "Held note lift (em)", path: \.heldLift, range: 0...0.4, step: 0.01, key: "heldLift"),
        Knob(section: "Karaoke", label: "Held note swell", path: \.heldScale, range: 1...1.4, step: 0.01, key: "heldScale"),
        Knob(section: "Karaoke", label: "Held note settle", path: \.heldSettle, range: 0...1, step: 0.05, key: "heldSettle"),
        Knob(section: "Karaoke", label: "Background vocal size", path: \.backgroundVocalSize, range: 0.4...1, step: 0.01, key: "backgroundVocalSize"),
        Knob(section: "Karaoke", label: "Background vocal opacity", path: \.backgroundVocalOpacity, range: 0...1, step: 0.01, key: "backgroundVocalOpacity"),
        Knob(section: "Motion", label: "Line fade (s)", path: \.fadeSeconds, range: 0...2, step: 0.05, key: "fadeSeconds"),
        Knob(section: "Motion", label: "Ripple per line (s)", path: \.rippleSeconds, range: 0...0.4, step: 0.01, key: "rippleSeconds"),
        Knob(section: "Background colors", label: "Saturation", path: \.bgSaturation, range: 0...2, step: 0.05, key: "bgSaturation"),
        Knob(section: "Background colors", label: "Brightness", path: \.bgBrightness, range: -0.5...0.5, step: 0.01, key: "bgBrightness"),
        Knob(section: "Background colors", label: "Intensity", path: \.bgIntensity, range: 0...2, step: 0.05, key: "bgIntensity"),
        Knob(section: "Background colors", label: "Drift speed", path: \.bgSpeed, range: 0...5, step: 0.1, key: "bgSpeed"),
        Knob(section: "Background colors", label: "Blur", path: \.bgBlur, range: 0...80, step: 1, key: "bgBlur"),
        Knob(section: "Controls", label: "Hide after (s)", path: \.controlsIdleSeconds, range: 1...20, step: 0.5, key: "controlsIdleSeconds"),
        Knob(section: "Controls", label: "Hide after a touch (s)", path: \.controlsWokenIdleSeconds, range: 1...30, step: 0.5, key: "controlsWokenIdleSeconds"),
    ]

    private static let storeKey = "cascade.styleTuning"

    var values: Values { didSet { save() } }

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
}

#if DEBUG && os(iOS)
/// The tuning panel, from Now Playing's ··· menu. A short sheet the player
/// stays live behind, so each change shows as it is made.
struct StyleTuningSheet: View {
    @Bindable private var tuning = StyleTuning.shared
    @Environment(\.dismiss) private var dismiss

    private var sections: [String] {
        StyleTuning.knobs.map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(StyleTuning.knobs.filter { $0.section == section }, id: \.key) { knob in
                            row(knob)
                        }
                    }
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

    private func row(_ knob: StyleTuning.Knob) -> some View {
        let value = tuning.values[keyPath: knob.path]
        let changed = value != StyleTuning.Values()[keyPath: knob.path]
        return VStack(alignment: .leading, spacing: 2) {
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
        // Double tap the row to put one knob back.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tuning.values[keyPath: knob.path] = StyleTuning.Values()[keyPath: knob.path] }
    }
}
#endif
