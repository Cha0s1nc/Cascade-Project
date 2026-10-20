import SwiftUI

/// The Mac's View > Zoom factor (MacZoom), 1 everywhere else. macOS ignores Dynamic Type and a
/// scaleEffect over the window renders text soft, so the zoom is carried down as a number and
/// the views that size text, art and rows read it: text stays sharp at every step.
private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// A text style that follows the zoom: the style itself at 1 (so iOS keeps Dynamic Type), else
/// the Mac's point size for it times the zoom.
private struct ScaledFont: ViewModifier {
    let style: Font.TextStyle
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        content.font(scale == 1 ? .system(style) : .system(size: Self.points(style) * scale, weight: style == .headline ? .bold : .regular))
    }

    /// macOS's sizes for each style.
    static func points(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        default: 13
        }
    }
}

extension View {
    func scaledFont(_ style: Font.TextStyle) -> some View { modifier(ScaledFont(style: style)) }
}
