import SwiftUI
import AppKit
import CascadeKit

/// The Theme panel's settings as the app lives with them: Dark or Light, the gradient whose
/// end is the accent, the album-art accent that replaces it, the UI font, and the two
/// Now Playing background knobs. Shared and long-lived (like StyleTuning) so the panel, the
/// overlay and the app's tint all read one copy. Saved under the desktop's store keys with
/// the desktop's value shapes (`theme` and `npTuning` as JSON strings, `uiFont` as a JSON
/// object string), so the settings import is a copy.
@MainActor
@Observable
final class MacTheme {
    static let shared = MacTheme()

    var settings: ThemeSettings {
        didSet {
            UserDefaults.standard.set(settings.encoded(), forKey: "cascade.theme")
            // Turning art accent off drops what the last cover gave, so the gradient is what shows.
            if !settings.albumArt { art = nil }
        }
    }

    /// Background dim, blend and (kept for the import) lyric scale.
    var tuning: NPTuning.Values {
        didSet { UserDefaults.standard.set(tuning.encoded(), forKey: "cascade.npTuning") }
    }

    private(set) var fontPreset: String
    private(set) var fontCustom: String

    /// What the playing cover gave the theme, while album-art accent is on.
    private(set) var art: ArtTheme?

    private init() {
        let d = UserDefaults.standard
        settings = ThemeSettings(stored: d.string(forKey: "cascade.theme"))
        tuning = NPTuning.Values(stored: d.string(forKey: "cascade.npTuning"))
        var preset = "system", custom = ""
        if let data = d.string(forKey: "cascade.uiFont")?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            preset = AppFont.validPreset(object["preset"] as? String)
            custom = object["custom"] as? String ?? ""
        }
        fontPreset = preset
        fontCustom = custom
    }

    func setFont(preset: String, custom: String) {
        fontPreset = AppFont.validPreset(preset)
        fontCustom = String(custom.prefix(60))
        let object: [String: Any] = ["preset": fontPreset, "custom": fontCustom]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "cascade.uiFont")
        }
    }

    var isLight: Bool { settings.mode == .light }

    /// The accent end of the gradient, or the cover's while album-art accent is on and
    /// one has been worked out. It drives the app's tint.
    var accentHex: String { settings.albumArt ? (art?.end ?? settings.gradEnd) : settings.gradEnd }
    var accent: Color { Color(hex: accentHex) }

    var font: AppFont.Resolved { AppFont.resolve(preset: fontPreset, custom: fontCustom) }

    /// Palette for the playing cover under the current theme, then its accent. One extraction
    /// serves the accent and the Now Playing background (CoverPalettes caches it), so the two
    /// can never disagree about the cover's colour.
    func refreshArt(itemId: String?, client: JellyfinClient?) async {
        guard settings.albumArt, let itemId, let client else { return }
        let colors = await CoverPalettes.palette(for: itemId, client: client, light: isLight)
        guard !Task.isCancelled, settings.albumArt else { return }
        // No cover (or none that decoded) leaves the gradient's accent, rather than the grey
        // an ArtTheme gives a monochrome cover.
        let next = colors.isEmpty ? nil : ArtTheme(from: colors)
        if next != art { art = next }
    }
}

extension Color {
    /// `#rrggbb`; anything else is the default accent's purple, never a crash.
    init(hex: String) {
        let c = HexColor.rgb(hex) ?? (0x7c, 0x3a, 0xed)
        self.init(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    /// Back to `#rrggbb` in sRGB, for the colour pickers.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemPurple
        return HexColor.string(r: Int((ns.redComponent * 255).rounded()), g: Int((ns.greenComponent * 255).rounded()),
                               b: Int((ns.blueComponent * 255).rounded()))
    }
}

/// Applies the theme to a window's content: Dark or Light, the accent as the tint, and the UI
/// font. Put on the root of every window that should follow it (the main window and Settings
/// get it from CascadeApp). A custom or serif family sets the default text font, so it
/// reaches text that does not pick a style of its own; the monospace choice is a design, which
/// reaches every style.
struct MacThemed: ViewModifier {
    @Environment(AppState.self) private var state
    private var theme: MacTheme { .shared }

    func body(content: Content) -> some View {
        let artId = state.player?.item.map { $0.albumId ?? $0.id }
        content
            .tint(theme.accent)
            .preferredColorScheme(theme.isLight ? .light : .dark)
            .modifier(FontChoice(font: theme.font))
            .task(id: "\(artId ?? "")|\(theme.settings.albumArt)|\(theme.isLight)") {
                await theme.refreshArt(itemId: artId, client: state.client)
            }
    }
}

private struct FontChoice: ViewModifier {
    let font: AppFont.Resolved
    func body(content: Content) -> some View {
        switch font {
        case .system: content
        case .monospaced: content.fontDesign(.monospaced)
        case .family(let name): content.font(.custom(name, size: NSFont.systemFontSize))
        }
    }
}

extension View {
    /// The Theme panel's look, for the root of a window's content.
    func macThemed() -> some View { modifier(MacThemed()) }
}
