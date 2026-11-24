import SwiftUI
import CascadeKit

// Personality v1's small parts shared by every Apple app: the page header with its voice
// line, section titles, chips, pill and icon buttons, the like button. They started on the
// Mac (App/Mac/MacLibraryStyle.swift keeps the Mac-only pieces: tiles, the detail header,
// track rows, the settings form) and moved here for the iPhone's restyle, as the Penpot
// "SwiftUI / iPhone" boards draw them.

extension View {
    /// Hover where there is a pointer (Mac, iPad with a trackpad); the TV has none.
    func cxHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: action)
        #endif
    }
}

/// The big title, the voice line under it, the page's buttons at the right and its
/// chips below.
struct CxPageHeader<Actions: View, Below: View>: View {
    let title: String
    var voice: String?
    @ViewBuilder var actions: Actions
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).cx(.hero).foregroundStyle(Cx.text).lineLimit(1)
                    if let voice { Text(voice).cx(.voice).foregroundStyle(Cx.text2).lineLimit(1) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions }
            }
            below
        }
        .padding(.bottom, 22)
    }
}

/// A chip's face: 12 pt medium on the surface, accent on its tint when on.
struct CxChipLabel: View {
    let title: String
    var symbol: String?
    var on = false
    var hovering = false
    @Environment(\.uiScale) private var zoom

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title)
        }
        .font(.cxBody(12 * zoom, .medium))
        .foregroundStyle(on ? Cx.accent : Cx.text2)
        .padding(.horizontal, 14 * zoom).padding(.vertical, 7 * zoom)
        .background(on ? Cx.accentTint : hovering ? Cx.surface2 : Cx.surface, in: Capsule())
        .contentShape(Capsule())
    }
}

struct CxChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { CxChipLabel(title: title, on: on, hovering: hovering) }
            .buttonStyle(.plain)
            .cxHover { hovering = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A chip that opens a menu: Genre, Decade, Played, the sort.
struct CxMenuChip<Content: View>: View {
    let title: String
    var symbol: String?
    var on = false
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { CxChipLabel(title: title, symbol: symbol, on: on) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// The page's buttons: Play in the accent, the rest on the surface.
struct PillButton: View {
    let title: String
    let symbol: String?
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
                .cx(.strong)
                .foregroundStyle(primary ? Cx.ink : Cx.text)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(primary ? Cx.accent : hovering ? Cx.hover : Cx.surface2, in: Capsule())
                .brightness(primary && hovering ? 0.06 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .cxHover { hovering = $0 }
    }
}

/// A bare icon in the header's row: like, download, more.
struct CxIconButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var zoom

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16 * zoom, weight: .medium))
                .foregroundStyle(tint ?? (hovering ? Cx.text : Cx.text2))
                .frame(width: 32 * zoom, height: 32 * zoom)
                .background(hovering ? Cx.line : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .cxHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A section title inside a page, with an optional quiet note or link at the right.
struct CxSectionTitle: View {
    let title: String
    var note: String?
    var top: CGFloat = 30
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).cx(.section).foregroundStyle(Cx.text)
            Spacer()
            if let note { Text(note).cx(.small).foregroundStyle(Cx.text2) }
        }
        .padding(.top, top).padding(.bottom, 14)
    }
}

/// A count in words, with thousands: "1,204 albums".
func cxCount(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted(.number.locale(Locale(identifier: "en_US")))) \(n == 1 ? one : many ?? one + "s")"
}

/// The header's heart: flips only once the server says yes (CODEMAP rule 1).
struct CxLikeButton: View {
    let item: JfItem
    @Environment(AppState.self) private var state
    @State private var favorite: Bool?
    private var isFavorite: Bool { favorite ?? item.userData?.isFavorite ?? false }

    var body: some View {
        CxIconButton(symbol: isFavorite ? "heart.fill" : "heart", help: isFavorite ? "Unlike" : "Like",
                     tint: isFavorite ? Cx.like : nil) {
            guard let client = state.client else { return }
            let target = !isFavorite
            Task {
                do {
                    try await client.setFavorite(target, itemId: item.id)
                    favorite = target
                } catch {
                    announceWriteFailed(target ? "add to Favorites" : "remove from Favorites")
                }
            }
        }
        .disabled(state.isOffline)
    }
}
