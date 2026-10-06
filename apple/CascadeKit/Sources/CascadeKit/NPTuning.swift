import Foundation

// The Now Playing look's user settings that are not StyleTuning knobs: the
// desktop's npTuning (src/core/np-tuning.ts) and its UI font choice
// (src/core/font.ts). Store values are untrusted, as everywhere a stored number
// could reach a layout value: a corrupted or hand-edited setting must clamp to
// something safe rather than arrive as NaN.

public enum NPTuning {
    /// Multiplier on the lyric size. 1 is the shipped size; the range stops short
    /// of illegible-small and line-wrapping-large. On the Mac the Lyrics page's
    /// "Text size" knob (StyleTuning.lyricSize) is the live control; this is kept
    /// for the settings import, which maps Electron's `npTuning.lyricScale`.
    public static let lyricScaleRange = 0.8...1.4
    public static let lyricScaleDefault = 1.0

    /// How much white scrim the light theme lays over the album-art background
    /// behind the left column, the lyrics panel and the header.
    public static let bgDimRange = 0.0...1.0
    public static let bgDimDefault = 0.16

    public static func clampLyricScale(_ n: Double?) -> Double { clamp(n, lyricScaleRange, lyricScaleDefault) }
    public static func clampBgDim(_ n: Double?) -> Double { clamp(n, bgDimRange, bgDimDefault) }

    /// Multiply is the shipped blend, and only an explicit false turns it off: a
    /// stale or corrupt value reads as the default rather than as an unblended overlay.
    public static func clampBgBlend(_ v: Any?) -> Bool { (v as? Bool) != false }

    private static func clamp(_ n: Double?, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard let n, n.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, n))
    }

    /// The three values as stored: one JSON object under `cascade.npTuning`, the
    /// shape electron-store keeps (`{"lyricScale":1,"bgDim":0.16,"bgBlend":true}`).
    public struct Values: Equatable, Sendable {
        public var lyricScale = NPTuning.lyricScaleDefault
        public var bgDim = NPTuning.bgDimDefault
        public var bgBlend = true

        public init() {}

        /// Whatever was stored, made safe. Garbage of any kind gives the defaults.
        public init(stored json: String?) {
            self.init()
            guard let data = json?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lyricScale = NPTuning.clampLyricScale((object["lyricScale"] as? NSNumber)?.doubleValue)
            bgDim = NPTuning.clampBgDim((object["bgDim"] as? NSNumber)?.doubleValue)
            bgBlend = NPTuning.clampBgBlend(object["bgBlend"])
        }

        public func encoded() -> String {
            let object: [String: Any] = ["lyricScale": lyricScale, "bgDim": bgDim, "bgBlend": bgBlend]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// The UI font choice (Theme panel > Font): four presets and a custom family.
public enum AppFont {
    public static let presets: [(id: String, label: String)] = [
        ("system", "System"), ("sans", "Helvetica"), ("serif", "Georgia"), ("mono", "Monospace"), ("custom", "Custom"),
    ]

    /// What the view layer should draw with.
    public enum Resolved: Equatable, Sendable {
        case system
        case monospaced
        case family(String)
    }

    /// Restricts a user-typed font family to letters, digits, spaces and hyphens, at
    /// most 60 characters. Anything else is dropped rather than escaped: a family name
    /// never legitimately needs quotes, semicolons or braces.
    public static func sanitize(_ input: String?) -> String {
        guard let input else { return "" }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(60).unicodeScalars.filter { s in
            (s.value >= 0x30 && s.value <= 0x39) || (s.value >= 0x41 && s.value <= 0x5A)
                || (s.value >= 0x61 && s.value <= 0x7A) || s == " " || s == "-"
        })
    }

    /// A stored (preset, custom name) pair as a font. An unknown preset (a stale value
    /// from a build with different presets) and an empty or all-stripped custom name
    /// both fall back to the system font rather than to nothing.
    public static func resolve(preset: String?, custom: String? = nil) -> Resolved {
        switch preset {
        case "custom":
            let name = sanitize(custom)
            return name.isEmpty ? .system : .family(name)
        case "sans": return .family("Helvetica")
        case "serif": return .family("Georgia")
        case "mono": return .monospaced
        default: return .system
        }
    }

    /// A preset id that exists, for showing in a picker: a stale one reads as System.
    public static func validPreset(_ preset: String?) -> String {
        presets.contains { $0.id == preset } ? preset! : "system"
    }
}
