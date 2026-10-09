import Foundation

/// The server style: a look an administrator sets in Cascade Server (the
/// `server-style` capability, GET /CascadeServer/Style) for everyone on the
/// server. The desktop's src/core/server-style.ts, with the same rules:
/// "default" fills in what a person never set themselves; "enforced" puts the
/// server's colors and/or lyrics over their own. Light or dark mode and the
/// font always stay theirs. Layered over stored settings, never saved into them.
public struct ServerStyle: Equatable, Sendable {
    public enum Mode: String, Sendable { case off, `default`, enforced }
    /// How the server's look meets one part of a person's settings.
    public enum Part: Sendable { case none, fill, force }

    public var mode = Mode.off
    public var enforceTheme = false
    public var enforceLyrics = false
    public var preset: CascadePreset?

    public init() {}
    public static let off = ServerStyle()

    /// The plugin's reply, checked as any preset is. Anything unexpected is off.
    public static func parse(_ data: Data) -> ServerStyle {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = (raw["mode"] as? String).flatMap(Mode.init(rawValue:)), mode != .off,
              let presetObject = raw["preset"] as? [String: Any],
              let presetData = try? JSONSerialization.data(withJSONObject: presetObject),
              case .success(let preset) = CascadePreset.parse(String(decoding: presetData, as: UTF8.self)) else { return .off }
        let enforce = raw["enforce"] as? [String: Any] ?? [:]
        var s = ServerStyle()
        s.mode = mode
        s.enforceTheme = mode == .enforced && enforce["theme"] as? Bool == true
        s.enforceLyrics = mode == .enforced && enforce["lyrics"] as? Bool == true
        s.preset = preset
        return s
    }

    public var themePart: Part { part(has: preset?.theme != nil, forced: enforceTheme) }
    public var lyricsPart: Part { part(has: preset?.lyrics != nil, forced: enforceLyrics) }

    private func part(has: Bool, forced: Bool) -> Part {
        guard mode != .off, has else { return .none }
        return forced ? .force : .fill
    }

    /// The lyric knob changes to use: the person's own with the server's under
    /// them (fill) or the server's whole (force).
    public func layeredLyricChanges(_ mine: [String: Double]) -> [String: Double] {
        let server = preset?.lyrics?.style ?? [:]
        switch lyricsPart {
        case .force: return server
        case .fill: return server.merging(mine) { _, own in own }
        case .none: return mine
        }
    }

    /// Which Now Playing tuning values a person stored themselves.
    public struct TuningSet: Equatable, Sendable {
        public var bgDim = false, bgBlend = false, lyricScale = false
        public init(bgDim: Bool = false, bgBlend: Bool = false, lyricScale: Bool = false) {
            (self.bgDim, self.bgBlend, self.lyricScale) = (bgDim, bgBlend, lyricScale)
        }
        public static let all = TuningSet(bgDim: true, bgBlend: true, lyricScale: true)

        public init(stored json: String?) {
            let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            self.init(bgDim: object["bgDim"] != nil, bgBlend: object["bgBlend"] != nil, lyricScale: object["lyricScale"] != nil)
        }
    }

    /// The colors and Now Playing tuning to use. `colorsSet` and `tuningSet`
    /// say what the person stored themselves (see colorsSet(stored:)).
    public func layered(theme: ThemeSettings, colorsSet: Bool, tuning: NPTuning.Values, tuningSet: TuningSet)
        -> (theme: ThemeSettings, tuning: NPTuning.Values) {
        var outTheme = theme, outTuning = tuning
        if let t = preset?.theme {
            if themePart == .force || (themePart == .fill && !colorsSet) {
                (outTheme.gradStart, outTheme.gradEnd, outTheme.albumArt) = (t.gradStart, t.gradEnd, t.albumArt)
            }
            if themePart == .force || (themePart == .fill && !tuningSet.bgDim) { outTuning.bgDim = t.bgDim }
            if themePart == .force || (themePart == .fill && !tuningSet.bgBlend) { outTuning.bgBlend = t.bgBlend }
        }
        if let l = preset?.lyrics, lyricsPart == .force || (lyricsPart == .fill && !tuningSet.lyricScale) {
            outTuning.lyricScale = l.lyricScale
        }
        return (outTheme, outTuning)
    }

    // MARK: Saving under a style
    //
    // A value that only shows the server's look through is not the person's
    // own: saving it would keep the server's look after an admin turned the
    // style off (switching light/dark saves the whole theme). What they had
    // stored, or nothing, stays instead. The desktop's ownValue.

    /// The theme to store for `shown`.
    public func ownTheme(_ shown: ThemeSettings, stored: String?) -> ThemeSettings {
        guard themePart != .none, let t = preset?.theme else { return shown }
        let mine = ThemeSettings(stored: stored)
        var out = shown
        if shown.gradStart == t.gradStart, shown.gradEnd == t.gradEnd { (out.gradStart, out.gradEnd) = (mine.gradStart, mine.gradEnd) }
        if shown.albumArt == t.albumArt { out.albumArt = mine.albumArt }
        return out
    }

    /// The tuning to store for `shown`, as JSON with only the person's own values.
    public func ownTuning(_ shown: NPTuning.Values, stored: String?) -> String {
        let mine = stored.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        var object: [String: Any] = ["lyricScale": shown.lyricScale, "bgDim": shown.bgDim, "bgBlend": shown.bgBlend]
        if themePart != .none, let t = preset?.theme {
            if shown.bgDim == t.bgDim { object["bgDim"] = mine["bgDim"] }
            if shown.bgBlend == t.bgBlend { object["bgBlend"] = mine["bgBlend"] }
        }
        if lyricsPart != .none, let l = preset?.lyrics, shown.lyricScale == l.lyricScale { object["lyricScale"] = mine["lyricScale"] }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The lyric knob changes to store for `changes`.
    public func ownLyricChanges(_ changes: [String: Double], stored: [String: Double]) -> [String: Double] {
        guard lyricsPart != .none, let server = preset?.lyrics?.style else { return changes }
        var out = changes
        for (key, value) in server where changes[key] == value { out[key] = stored[key] }
        return out
    }

    /// Whether a stored theme carries colors the person chose: off the shipped
    /// gradient, or the album-art accent. Switching light/dark alone also
    /// writes the theme, so its presence is not enough.
    public static func colorsSet(stored json: String?) -> Bool {
        guard json != nil else { return false }
        let t = ThemeSettings(stored: json), d = ThemeSettings()
        return t.albumArt || t.gradStart != d.gradStart || t.gradEnd != d.gradEnd
    }
}
