import SwiftUI
import CascadeKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Personality v1, the look Cascade shares across apps: the colors and type of the Penpot
/// file "Cascade Personality v1" (library colors under Cascade, type tokens in the Cascade
/// set), as Flutter's K and Txt in flutter/lib/ui/widgets.dart have them. Where the running
/// Flutter app moved off the mockup, this follows Flutter: text3 is lighter than Penpot's
/// #687789 for 4.5:1 contrast, and there is a Light palette.
///
/// Every color follows the appearance the view is drawn in, so the Mac theme's Dark and
/// Light (preferredColorScheme) repaint them in place. The accent is not here: it stays the
/// theme's (gradient end, album art, server style), read through `Cx.accent`.
enum Cx {
    static let bg = Color(dark: 0x0A0E13, light: 0xF2F2F7)
    /// Panels, the player bar, the sidebar under its glass. Flutter's `panel`.
    static let surface = Color(dark: 0x111821, light: 0xFFFFFF)
    /// Fields, cards and buttons on a surface. Flutter's `surface`.
    static let surface2 = Color(dark: 0x18222E, light: 0xFFFFFF)
    /// A step above surface2, for hover. Flutter's `surface2`.
    static let hover = Color(dark: 0x223041, light: 0xE8E8ED)
    static let line = Color(dark: 0xFFFFFF, light: 0x000000, darkOpacity: 0.08, lightOpacity: 0.10)
    /// The unfilled part of a bar (scrubber, volume).
    static let track = Color(dark: 0xFFFFFF, light: 0x000000, darkOpacity: 0.12, lightOpacity: 0.12)
    static let text = Color(dark: 0xEEF3F8, light: 0x1C1C1E)
    static let text2 = Color(dark: 0xA7B4C4, light: 0x48484A)
    static let text3 = Color(dark: 0x8A99AB, light: 0x636366)
    static let accentDeep = Color(dark: 0x2B6CB0, light: 0x1E4F86)
    /// Text and icons on the accent: dark on the light blue, white on Light's darker one.
    static let ink = Color(dark: 0x06121F, light: 0xFFFFFF)
    static let foam = Color(dark: 0xD7EEFF, light: 0x3A7FC6)
    static let like = Color(dark: 0xFF6B8A, light: 0xC2255C)

    @MainActor static var accent: Color {
        #if os(macOS)
        MacTheme.shared.accent
        #else
        Color.accentColor
        #endif
    }
    /// The active sidebar row and selected chips: the accent at 14%.
    @MainActor static var accentTint: Color { accent.opacity(0.14) }

    /// The blue wash down from the top of a page (Penpot's "Spray").
    static let wash = LinearGradient(colors: [Color(dark: 0x2B6CB0, light: 0x2B6CB0, darkOpacity: 0.38, lightOpacity: 0.18),
                                              Color(dark: 0x2B6CB0, light: 0x2B6CB0, darkOpacity: 0, lightOpacity: 0)],
                                     startPoint: .top, endPoint: .bottom)
}

/// The type tokens (Penpot set "Cascade"). Display styles use font.display (Hanken
/// Grotesk), body styles font.body (Inter), both bundled.
enum CxType {
    case hero, title, section, voice, brand
    case strong, row, regular, small, caps

    var size: CGFloat {
        switch self {
        // The iPhone's page titles are 30 (Penpot "SwiftUI / iPhone"); every other token
        // is the same size on both.
        #if os(iOS)
        case .hero: 30
        #else
        case .hero: 44
        #endif
        case .title: 30
        case .section: 21
        case .voice, .brand: 17
        case .strong: 14
        case .row, .regular: 13
        case .small: 12
        case .caps: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .voice, .regular, .small: .regular
        case .row: .medium
        default: .semibold
        }
    }

    var isDisplay: Bool { [.hero, .title, .section, .voice, .brand].contains(self) }
    var italic: Bool { self == .voice }
}

extension Font {
    /// font.display (Hanken Grotesk) at a size and weight.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold, italic: Bool = false) -> Font {
        CxFonts.font(CxFonts.postScript(family: "HankenGrotesk", weight: weight, italic: italic), size)
    }

    /// font.body (Inter), unless the person chose a UI font of their own in the Theme panel.
    @MainActor static func cxBody(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        #if os(macOS)
        switch MacTheme.shared.font {
        case .system: break
        case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
        case .family(let name): return .custom(name, fixedSize: size).weight(weight)
        }
        #endif
        return CxFonts.font(CxFonts.postScript(family: "Inter", weight: weight, italic: false), size)
    }
}

enum CxFonts {
    /// A bundled face at a size. The Mac keeps the size as given (View > Zoom scales it);
    /// the iPhone grows it with Dynamic Type, each size on the curve of the text style
    /// nearest it, so a 34 pt title grows as a large title does and not as body text.
    static func font(_ name: String, _ size: CGFloat) -> Font {
        #if os(macOS)
        .custom(name, fixedSize: size)
        #else
        .custom(name, size: size, relativeTo: textStyle(for: size))
        #endif
    }

    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case 34...: .largeTitle
        case 28..<34: .title
        case 22..<28: .title2
        case 20..<22: .title3
        case 17..<20: .body
        case 15..<17: .subheadline
        case 13..<15: .footnote
        case 12..<13: .caption
        default: .caption2
        }
    }

    /// The bundled faces' PostScript names (flutter/assets/fonts, one copy for both apps).
    /// Named directly rather than by family plus weight, which falls back silently.
    static func postScript(family: String, weight: Font.Weight, italic: Bool) -> String {
        let face: String = switch weight {
        case .medium: "Medium"
        case .semibold: "SemiBold"
        case .bold, .heavy, .black: "Bold"
        default: "Regular"
        }
        // ponytail: only 400 and 600 italics are bundled (Hanken), as in Flutter.
        if italic { return "\(family)-\(face == "Regular" ? "" : "SemiBold")Italic" }
        return "\(family)-\(face)"
    }
}

/// A type token at the Mac's View > Zoom (uiScale).
private struct CxFontModifier: ViewModifier {
    let type: CxType
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        let size = type.size * scale
        let font = type.isDisplay ? Font.display(size, type.weight, italic: type.italic) : Font.cxBody(size, type.weight)
        if type == .caps {
            content.font(font).tracking(0.88 * scale).textCase(.uppercase)
        } else {
            content.font(font)
        }
    }
}

extension View {
    /// One of the Personality v1 type tokens.
    func cx(_ type: CxType) -> some View { modifier(CxFontModifier(type: type)) }
}

extension Color {
    /// A color that follows the appearance it is drawn in.
    init(dark: UInt32, light: UInt32, darkOpacity: Double = 1, lightOpacity: Double = 1) {
        func parts(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
        }
        let (dr, dg, db) = parts(dark), (lr, lg, lb) = parts(light)
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dr, green: dg, blue: db, alpha: darkOpacity)
                : NSColor(srgbRed: lr, green: lg, blue: lb, alpha: lightOpacity)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: dr, green: dg, blue: db, alpha: darkOpacity)
                : UIColor(red: lr, green: lg, blue: lb, alpha: lightOpacity)
        })
        #endif
    }
}
