import SwiftUI

// Personality v1 across the whole iPhone app (Penpot "SwiftUI / iPhone"), set in a few
// places rather than on every screen: the bundled faces for every text style and for the
// navigation bar's titles, and the page background behind every pushed page. The accent
// is the asset catalog's AccentColor, the app's tint already. Screens with a board of their
// own (Home, Library, Album, Now Playing...) build on this with the Cx components. The TV
// and the Mac are untouched here.

#if os(iOS)
import UIKit

enum PhoneTheme {
    /// The bundled face for a text style at iOS's own size for it: Hanken Grotesk for the
    /// titles, Inter for the rest, scaled with Dynamic Type on that style's curve.
    static func font(_ style: Font.TextStyle) -> Font {
        let (size, weight, display): (CGFloat, Font.Weight, Bool) = switch style {
        case .largeTitle: (34, .semibold, true)
        case .title: (28, .semibold, true)
        case .title2: (22, .semibold, true)
        case .title3: (20, .semibold, true)
        case .headline: (17, .semibold, false)
        case .callout: (16, .regular, false)
        case .subheadline: (15, .regular, false)
        case .footnote: (13, .regular, false)
        case .caption: (12, .regular, false)
        case .caption2: (11, .regular, false)
        default: (17, .regular, false)
        }
        let name = CxFonts.postScript(family: display ? "HankenGrotesk" : "Inter", weight: weight, italic: false)
        return .custom(name, size: size, relativeTo: style)
    }

    /// The navigation bar's titles in the bundled faces: the large title as the boards'
    /// page title, the inline one as Inter, both following Dynamic Type.
    static func applyNavigationBar() {
        func ui(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont {
            let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
            return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        }
        let text = UIColor(Cx.text)
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: ui("HankenGrotesk-SemiBold", 32, .largeTitle), .foregroundColor: text]
        appearance.titleTextAttributes = [.font: ui("Inter-SemiBold", 16, .headline), .foregroundColor: text]
    }
}

extension View {
    /// The app-wide look, set once at the root.
    func phoneTheme() -> some View {
        self
            // No app-wide default font: set at the root it also overrode the smaller styles
            // the system gives list section headers and footers (78 of them), so footers came
            // out at body size. Text without a font of its own stays San Francisco.
            // The asset catalog's color by name: Cx.accent is Color.accentColor, which
            // resolved to the system blue under these modifiers (and tinting with it again
            // only refers it to itself).
            .tint(Color("AccentColor"))
            // Lists and forms show the page's background instead of their own gray.
            .scrollContentBackground(.hidden)
    }

    /// The page background, on every page a stack shows (TabStack's root and each pushed page).
    func cxPageBackground() -> some View {
        containerBackground(Cx.bg, for: .navigation)
    }

    /// A grouped list's rows as the boards' cards (Penpot "iPhone / Settings"): on the surface.
    func cxListRows() -> some View {
        listRowBackground(Cx.surface)
    }
}
#else
extension View {
    func phoneTheme() -> some View { self }
    func cxPageBackground() -> some View { self }
    func cxListRows() -> some View { self }
}
#endif
