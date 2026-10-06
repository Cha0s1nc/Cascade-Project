import Foundation

// The Theme panel's colour settings: Dark or Light, a two-colour gradient whose
// end is the accent, eight presets, and the album-art accent that overrides the
// gradient. The desktop's renderer.js "Theme system", without its DOM. Pure, so
// a stored value is validated in one place: it arrives as JSON from
// electron-store's `theme` key and is untrusted.

public struct ThemePreset: Equatable, Sendable, Identifiable {
    public let label: String
    public let start: String
    public let end: String
    public var id: String { label }

    public static let all: [ThemePreset] = [
        ThemePreset(label: "Default", start: "#4ade80", end: "#7c3aed"),
        ThemePreset(label: "Sunset", start: "#f97316", end: "#ec4899"),
        ThemePreset(label: "Ocean", start: "#06b6d4", end: "#3b82f6"),
        ThemePreset(label: "Rose", start: "#fb7185", end: "#e11d48"),
        ThemePreset(label: "Gold", start: "#fbbf24", end: "#f59e0b"),
        ThemePreset(label: "Mint", start: "#34d399", end: "#059669"),
        ThemePreset(label: "Candy", start: "#f472b6", end: "#818cf8"),
        ThemePreset(label: "Fire", start: "#ef4444", end: "#f97316"),
    ]
}

/// `#rrggbb` colours, which is all the theme ever stores.
public enum HexColor {
    public static func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        guard hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    public static func isValid(_ hex: String) -> Bool { rgb(hex) != nil }

    public static func string(r: Int, g: Int, b: Int) -> String {
        String(format: "#%02x%02x%02x", min(255, max(0, r)), min(255, max(0, g)), min(255, max(0, b)))
    }

    /// Perceived luminance 0-255, to pick a readable ink over the colour.
    public static func luminance(_ hex: String) -> Double {
        guard let c = rgb(hex) else { return 0 }
        return 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
    }

    /// The play button's ink: black on a light accent so it stays readable, white otherwise.
    public static func prefersDarkInk(over hex: String) -> Bool { luminance(hex) > 160 }
}

public struct ThemeSettings: Equatable, Sendable {
    public enum Mode: String, Sendable { case dark, light }

    public var mode = Mode.dark
    public var gradStart = ThemePreset.all[0].start
    public var gradEnd = ThemePreset.all[0].end
    /// Colour the accent, and the Now Playing background, from the cover.
    public var albumArt = false

    public init() {}

    /// A stored theme, made safe. Each field that fails validation keeps its default, so
    /// one bad colour does not throw away the mode. (The desktop's stored shape:
    /// `{"mode":"dark","gradStart":"#4ade80","gradEnd":"#7c3aed","albumArt":false}`.)
    public init(stored json: String?) {
        self.init()
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let m = (object["mode"] as? String).flatMap(Mode.init(rawValue:)) { mode = m }
        if let s = object["gradStart"] as? String, let e = object["gradEnd"] as? String,
           HexColor.isValid(s), HexColor.isValid(e) {
            gradStart = s.lowercased()
            gradEnd = e.lowercased()
        }
        albumArt = (object["albumArt"] as? Bool) ?? false
    }

    public func encoded() -> String {
        let object: [String: Any] = ["mode": mode.rawValue, "gradStart": gradStart, "gradEnd": gradEnd, "albumArt": albumArt]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The preset the gradient matches, if any.
    public var activePreset: ThemePreset? {
        ThemePreset.all.first { $0.start == gradStart && $0.end == gradEnd }
    }
}

/// What the cover gives the theme: blob colours for the background and the
/// gradient pair the accent comes from (applyAlbumArtTheme).
public struct ArtTheme: Equatable, Sendable {
    public var blobs: [BlobColor]
    public var start: String
    public var end: String

    /// Below this saturation there is no hue worth trusting: what is left is JPEG noise on
    /// essentially monochrome art, and normalizing it would invent a colour that appears
    /// nowhere on the cover.
    static let neutralSaturation = 0.18

    /// One palette for the whole theme: the blobs decide, and the accent follows them,
    /// so the accent and the background can never disagree about the cover's colour.
    public init(from colors: [BlobColor]) {
        var h = 0.0, s = 0.0, l = 0.0
        if let top = colors.first { (h, s, l) = Self.hueSatLightness(top) }
        if colors.isEmpty || s < Self.neutralSaturation {
            // Monochrome or near enough: grey blobs off the art's own lightness where there
            // is one, so a bright black-and-white cover does not get the dark one's
            // treatment, and a neutral accent so the last track's colour does not bleed through.
            let lum: Double = colors.isEmpty ? 70 : (l * 255).rounded()
            let hi = min(255, (lum * 1.2).rounded())
            let lo = max(0, (lum * 0.6).rounded())
            blobs = [BlobColor(r: hi, g: hi, b: hi, hue: 0), BlobColor(r: lo, g: lo, b: lo, hue: 0)]
            start = "#505050"
            end = "#202020"
            return
        }
        blobs = colors
        // Normalized to a fixed lightness and saturation so muted covers still give an
        // accent you can tell apart from the last one; the hue is the palette's own.
        let hi = Self.rgb(hue: h, saturation: 0.85, lightness: 0.62)
        let lo = Self.rgb(hue: h, saturation: 0.90, lightness: 0.36)
        start = HexColor.string(r: hi.r, g: hi.g, b: hi.b)
        end = HexColor.string(r: lo.r, g: lo.g, b: lo.b)
    }

    static func hueSatLightness(_ c: BlobColor) -> (h: Double, s: Double, l: Double) {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l = (mx + mn) / 2
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d + (g < b ? 6 : 0)) / 6 }
            else if mx == g { h = ((b - r) / d + 2) / 6 }
            else { h = ((r - g) / d + 4) / 6 }
        }
        return (h, s, l)
    }

    static func rgb(hue: Double, saturation s: Double, lightness l: Double) -> (r: Int, g: Int, b: Int) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((hue * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let table: [(Double, Double, Double)] = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)]
        let (r, g, b) = table[Int(hue * 6) % 6]
        return (Int(((r + m) * 255).rounded()), Int(((g + m) * 255).rounded()), Int(((b + m) * 255).rounded()))
    }
}
