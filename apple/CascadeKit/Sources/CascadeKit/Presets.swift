import Foundation

/// Shareable looks: the theme (mode, colours, font) and the lyrics style, in
/// the desktop's `.cascadepreset` format (src/core/presets.ts), so a look
/// moves between the desktop and the Apple app as a file or pasted text.
///
/// A preset comes from someone else's computer, so every value is checked the
/// way the matching setting already is. A missing or wrong field takes the
/// shipped default, so applying a preset lands on one known look. The lyric
/// knobs are kept as numbers here and clamped to each knob's range by the app
/// when it applies them (StyleTuning lives in the app, not this package).
public struct CascadePreset: Equatable, Sendable {
    public static let format = "cascade-preset"
    public static let version = 1
    public static let fileExtension = "cascadepreset"
    /// Larger than any real preset by two orders of magnitude; refuses a
    /// pasted novel before JSON has to read it.
    public static let maxBytes = 64 * 1024
    /// The shipped gradient (ThemePreset.all[0], THEME_PRESETS[0] on desktop).
    public static let defaultGradient = (start: "#4ade80", end: "#7c3aed")
    static let nameMax = 60

    public struct Theme: Equatable, Sendable {
        public var mode: ThemeSettings.Mode
        public var gradStart: String
        public var gradEnd: String
        public var albumArt: Bool
        public var bgDim: Double
        public var bgBlend: Bool
        public var fontPreset: String
        public var fontCustom: String

        public init(mode: ThemeSettings.Mode, gradStart: String, gradEnd: String, albumArt: Bool,
                    bgDim: Double, bgBlend: Bool, fontPreset: String, fontCustom: String) {
            (self.mode, self.gradStart, self.gradEnd, self.albumArt) = (mode, gradStart, gradEnd, albumArt)
            (self.bgDim, self.bgBlend, self.fontPreset, self.fontCustom) = (bgDim, bgBlend, fontPreset, fontCustom)
        }
    }

    public struct Lyrics: Equatable, Sendable {
        /// Knob key to value, only the knobs that differ from the defaults.
        public var style: [String: Double]
        public var lyricScale: Double

        public init(style: [String: Double], lyricScale: Double) {
            self.style = style
            self.lyricScale = lyricScale
        }
    }

    public var name: String
    public var theme: Theme?
    public var lyrics: Lyrics?

    public init(name: String, theme: Theme? = nil, lyrics: Lyrics? = nil) {
        self.name = Self.cleanName(name)
        self.theme = theme
        self.lyrics = lyrics
    }

    // MARK: Checking

    /// Printable text only, trimmed and capped: a name is shown and used as a file name.
    public static func cleanName(_ v: Any?) -> String {
        let s = (v as? String).map { raw in
            String(String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }).trimmingCharacters(in: .whitespaces).prefix(nameMax))
        } ?? ""
        return s.isEmpty ? "Untitled" : s
    }

    private static func hex(_ v: Any?, _ fallback: String) -> String {
        guard let s = v as? String, s.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return fallback }
        return s.lowercased()
    }

    /// JSON numbers only (not booleans, which Foundation also bridges to NSNumber).
    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    public static func theme(_ v: Any?) -> Theme {
        let t = v as? [String: Any] ?? [:]
        let font = t["font"] as? [String: Any] ?? [:]
        let preset = AppFont.validPreset(font["preset"] as? String)
        return Theme(
            mode: (t["mode"] as? String) == "light" ? .light : .dark,
            gradStart: hex(t["gradStart"], defaultGradient.start),
            gradEnd: hex(t["gradEnd"], defaultGradient.end),
            albumArt: (t["albumArt"] as? Bool) == true,
            bgDim: NPTuning.clampBgDim(number(t["bgDim"])),
            bgBlend: NPTuning.clampBgBlend(t["bgBlend"]),
            fontPreset: preset,
            fontCustom: preset == "custom" ? AppFont.sanitize(font["custom"] as? String) : "")
    }

    public static func lyrics(_ v: Any?) -> Lyrics {
        let l = v as? [String: Any] ?? [:]
        var style: [String: Double] = [:]
        for (key, value) in l["style"] as? [String: Any] ?? [:] {
            // Knob keys are short identifiers; anything else is not ours.
            guard key.count <= 40, key.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil,
                  let n = number(value) else { continue }
            style[key] = n
        }
        return Lyrics(style: style, lyricScale: NPTuning.clampLyricScale(number(l["lyricScale"])))
    }

    // MARK: Reading and writing

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case empty, tooLarge, notJSON, notPreset, noVersion, newer, nothingInIt

        /// The desktop's wording, so both apps say the same thing.
        public var description: String {
            switch self {
            case .empty: "That is empty."
            case .tooLarge: "That is too large to be a Cascade preset."
            case .notJSON: "That is not a Cascade preset (it is not valid JSON)."
            case .notPreset: "That is not a Cascade preset."
            case .noVersion: "That preset has no valid version."
            case .newer: "That preset was made by a newer Cascade. Update Cascade to use it."
            case .nothingInIt: "That preset has no theme or lyrics settings in it."
            }
        }
    }

    /// Reads a preset file or pasted text.
    public static func parse(_ text: String) -> Result<CascadePreset, ParseError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        guard text.utf8.count <= maxBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return .failure(.notJSON) }
        guard let raw = object as? [String: Any], raw["format"] as? String == format else { return .failure(.notPreset) }
        guard let n = number(raw["version"]), n == n.rounded(), n >= 1 else { return .failure(.noVersion) }
        guard Int(n) <= version else { return .failure(.newer) }
        let themeObject = raw["theme"] as? [String: Any]
        let lyricsObject = raw["lyrics"] as? [String: Any]
        guard themeObject != nil || lyricsObject != nil else { return .failure(.nothingInIt) }
        return .success(CascadePreset(name: cleanName(raw["name"]),
                                      theme: themeObject.map(theme),
                                      lyrics: lyricsObject.map(lyrics)))
    }

    /// Pretty JSON with the desktop's keys, ending in a newline.
    public func serialized() -> String {
        var object: [String: Any] = ["format": Self.format, "version": Self.version, "name": name]
        if let theme {
            object["theme"] = [
                "mode": theme.mode.rawValue, "gradStart": theme.gradStart, "gradEnd": theme.gradEnd,
                "albumArt": theme.albumArt, "bgDim": theme.bgDim, "bgBlend": theme.bgBlend,
                "font": ["preset": theme.fontPreset, "custom": theme.fontCustom],
            ] as [String: Any]
        }
        if let lyrics {
            object["lyrics"] = ["style": lyrics.style, "lyricScale": lyrics.lyricScale] as [String: Any]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// A file name for the save panel: the name with anything a file system
    /// might refuse replaced.
    public static func fileName(_ name: String) -> String {
        var base = cleanName(name).replacingOccurrences(of: "[\\\\/:*?\"<>|]+", with: "-", options: .regularExpression)
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "Cascade preset" : base).\(fileExtension)"
    }
}
