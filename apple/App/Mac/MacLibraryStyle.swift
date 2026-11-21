import SwiftUI
import CascadeKit

// The pieces the Mac's library pages are built from in Personality v1, as the Penpot
// "Mac / Songs", "Album", "Artist" and "Playlist" boards and Flutter's desktop pages
// (flutter/lib/ui/pages/common.dart and detail.dart): the page header with its voice
// line, filter chips, cards, and the big header an album, artist or playlist opens with.

extension View {
    /// A library page's margins, as Home's, grown with View > Zoom.
    func cxPage(bottom: CGFloat = 40) -> some View { modifier(CxPageMargins(bottom: bottom)) }
}

private struct CxPageMargins: ViewModifier {
    let bottom: CGFloat
    @Environment(\.uiScale) private var zoom
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36 * zoom).padding(.top, 30 * zoom).padding(.bottom, bottom * zoom)
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
            .onHover { hovering = $0 }
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

/// All, Favorites, Genre, Decade and Played as chips, bound to a screen's BrowseFilter
/// (the same stored filter the old Filter menu set).
struct FilterChips: View {
    @Binding var filter: BrowseFilter
    let itemType: String
    /// Artists: All and Favorites only (see ArtistsView's FilterMenu).
    var favoritesOnly = false
    @Environment(AppState.self) private var state
    @State private var genres: [String] = []
    @State private var decades: [Int] = []

    var body: some View {
        HStack(spacing: 8) {
            CxChip(title: "All", on: !filter.isActive) { filter = .init() }
            CxChip(title: "Favorites", on: filter.favoritesOnly) { filter.favoritesOnly.toggle() }
            if !favoritesOnly { menus }
        }
        .task(id: state.config?.libraryIds ?? []) {
            guard !favoritesOnly else { return }
            (genres, decades) = await FilterMenu.choices(state: state, itemType: itemType)
        }
    }

    @ViewBuilder private var menus: some View {
        if !genres.isEmpty {
            CxMenuChip(title: filter.genre ?? "Genre", on: filter.genre != nil) {
                Picker("Genre", selection: $filter.genre) {
                    Text("Any Genre").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            }
        }
        if !decades.isEmpty {
            CxMenuChip(title: filter.decade.map { "\(String($0))s" } ?? "Decade", on: filter.decade != nil) {
                Picker("Decade", selection: $filter.decade) {
                    Text("Any Decade").tag(Int?.none)
                    ForEach(decades, id: \.self) { Text("\(String($0))s").tag(Optional($0)) }
                }
                .pickerStyle(.inline)
            }
        }
        CxMenuChip(title: filter.played == .unplayed ? "Not played" : "Played",
                   on: filter.played != .any) {
            Picker("Played", selection: $filter.played) {
                Text("Played or Not").tag(BrowseFilter.Played.any)
                Text("Played").tag(BrowseFilter.Played.played)
                Text("Not Played").tag(BrowseFilter.Played.unplayed)
            }
            .pickerStyle(.inline)
        }
    }
}

/// The page's buttons: Play in the accent, the rest on the surface.
struct PillButton: View {
    let title: String
    let symbol: String
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .cx(.strong)
                .foregroundStyle(primary ? Cx.ink : Cx.text)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(primary ? Cx.accent : hovering ? Cx.hover : Cx.surface2, in: Capsule())
                .brightness(primary && hovering ? 0.06 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The header an album, artist or playlist page opens with: the art, a caps label, the
/// title, a meta line (an album's artist links), the voice line and the buttons, over a
/// wash in the cover's own color.
struct CxDetailHeader<Actions: View>: View {
    let label: String
    let title: String
    let artId: String?
    var round = false
    var lead: String?
    var leadId: String?
    var meta = ""
    var voice: String?
    @ViewBuilder var actions: Actions

    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var zoom
    @Environment(\.colorScheme) private var scheme
    @State private var tint: Color?

    var body: some View {
        HStack(alignment: .bottom, spacing: 28 * zoom) {
            ArtworkView(itemId: artId, size: 220)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).cx(.caps).foregroundStyle(Cx.text2)
                Text(title)
                    .font(.display(64 * zoom))
                    .foregroundStyle(Cx.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .padding(.top, 8)
                HStack(spacing: 0) {
                    if let lead {
                        ArtistLink(name: lead, id: leadId).font(.cxBody(13 * zoom, .medium))
                        if !meta.isEmpty { Text(" \u{00B7} ") }
                    }
                    Text(meta)
                }
                .cx(.regular)
                .foregroundStyle(Cx.text2)
                .lineLimit(1)
                .padding(.top, 10)
                if let voice, !voice.isEmpty {
                    Text(voice).cx(.voice).foregroundStyle(Cx.text2).padding(.top, 6)
                }
                HStack(spacing: 8) { actions }.padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 36 * zoom).padding(.top, 30 * zoom).padding(.bottom, 26 * zoom)
        // Its full height always: over a greedy list (the playlist page with its bulk bar),
        // the title's minimumScaleFactor let the header give up height by shrinking the title.
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) {
            LinearGradient(colors: [(tint ?? Cx.accentDeep).opacity(scheme == .dark ? 0.45 : 0.22), .clear],
                           startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -80)
                .allowsHitTesting(false)
        }
        .task(id: artId) {
            guard let artId, let client = state.client else { return }
            let colors = await CoverPalettes.palette(for: artId, client: client)
            // The most colorful of the cover's colors, as the wash.
            guard let c = colors.max(by: { $0.chroma < $1.chroma }) else { return }
            withAnimation(.easeOut(duration: 0.3)) { tint = Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255) }
        }
    }
}

/// An album, playlist or artist card (Flutter's MediaCard): the art (round for an
/// artist), its name and a line under it. Hovering lifts the name to the accent and,
/// for anything with songs, shows a play button on the art.
struct MacTile: View {
    let item: JfItem
    var subtitle: String?
    @Environment(AppState.self) private var state
    @State private var hovering = false

    private var isArtist: Bool { item.type == "MusicArtist" }

    var body: some View {
        VStack(alignment: isArtist ? .center : .leading, spacing: 0) {
            ArtworkView(itemId: item.id, size: 160, fillsFrame: true)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .shadow(color: .black.opacity(hovering && !isArtist ? 0.3 : 0), radius: 10, y: 4)
                .overlay(alignment: .bottomTrailing) {
                    if !isArtist {
                        Button { Task { await state.player?.play(await tracksOf(item, client: state.client)) } } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Cx.ink)
                                .frame(width: 40, height: 40)
                                .background(Cx.accent, in: Circle())
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .help("Play")
                        .padding(10)
                        .opacity(hovering ? 1 : 0)
                    }
                }
            Text(item.name ?? "Unknown")
                .cx(.row)
                .foregroundStyle(hovering ? Cx.accent : Cx.text)
                .lineLimit(1)
                .padding(.top, 10)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).cx(.small).foregroundStyle(Cx.text3).lineLimit(1).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: isArtist ? .center : .leading)
        .contentShape(Rectangle())
        .onHover { on in withAnimation(.easeOut(duration: 0.12)) { hovering = on } }
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

/// One song in an album, top songs or a list (Flutter's TrackRow): its number (the
/// playing bars while it plays, a play mark under the pointer), the title and a line
/// under it, plays and length. Click plays from here; right-click is its menu.
struct CxTrackRow: View {
    let track: JfItem
    let number: Int
    var showsArt = false
    var second: String?
    let play: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var zoom
    @State private var hovering = false

    var body: some View {
        let current = state.player?.item?.id == track.id
        let playing = current && state.player?.isPaused == false
        Button(action: play) {
            HStack(spacing: 0) {
                Group {
                    if playing {
                        PlayingIndicator(itemId: track.id)
                    } else if hovering {
                        Image(systemName: "play.fill").font(.system(size: 11 * zoom)).foregroundStyle(Cx.text)
                    } else {
                        Text("\(number)").cx(.small).monospacedDigit().foregroundStyle(current ? Cx.accent : Cx.text3)
                    }
                }
                .frame(width: 30 * zoom, alignment: .leading)
                if showsArt {
                    ArtworkView(itemId: track.albumId ?? track.id, size: 40).padding(.trailing, 12 * zoom)
                } else {
                    Spacer().frame(width: 8 * zoom)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "Unknown").cx(.row).foregroundStyle(current ? Cx.accent : Cx.text)
                        .lineLimit(1).explicitMark(track.id)
                    if let second, !second.isEmpty {
                        Text(second).cx(.small).foregroundStyle(Cx.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if let plays = track.userData?.playCount, plays > 0 {
                    Text(plays == 1 ? "1 play" : "\(plays) plays").cx(.small).foregroundStyle(Cx.text3)
                        .frame(width: 80 * zoom, alignment: .trailing)
                }
                Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "")
                    .cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
                    .frame(width: 52 * zoom, alignment: .trailing)
            }
            .padding(.horizontal, 12 * zoom)
            .frame(height: (showsArt ? 56 : 46) * zoom)
            .background(current ? Cx.surface2 : hovering ? Cx.line : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { on in withAnimation(.easeOut(duration: on ? 0.12 : 0.35)) { hovering = on } }
        .trackContextMenu(track)
    }
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
