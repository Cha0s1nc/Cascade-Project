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
    /// Stretch to the width offered: the phone's Play and Shuffle share a row.
    var wide = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, primary: Bool = false, wide: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.primary = primary
        self.wide = wide
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
                .cx(.strong)
                .foregroundStyle(primary ? Cx.ink : Cx.text)
                .padding(.horizontal, 16).padding(.vertical, wide ? 14 : 9)
                .frame(maxWidth: wide ? .infinity : nil)
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

/// A song in a phone list (Penpot "Cascade / Song row" and "Track row"): the cover, or the
/// track number on an album page, the title over a second line, and the length. The song
/// playing is in the accent. Tap plays from here; a long press is its menu.
struct CxSongRow: View {
    let track: JfItem
    /// An album page's track number in place of the cover.
    var number: Int?
    var second: String?
    let play: () -> Void
    @Environment(AppState.self) private var state

    var body: some View {
        let current = state.player?.item?.id == track.id
        Button(action: play) {
            HStack(spacing: 12) {
                if let number {
                    Group {
                        if current {
                            Image(systemName: "chart.bar.fill").imageScale(.small)
                        } else {
                            Text("\(number)").monospacedDigit()
                        }
                    }
                    .cx(.regular)
                    .foregroundStyle(current ? Cx.accent : Cx.text3)
                    .frame(width: 24, alignment: .leading)
                } else {
                    ArtworkView(itemId: track.albumId ?? track.id, size: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "Unknown").cx(.row).foregroundStyle(current ? Cx.accent : Cx.text)
                        .lineLimit(1).explicitMark(track.id)
                    if let second, !second.isEmpty {
                        Text(second).cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "")
                    .cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .trackContextMenu(track)
    }
}

/// The boards' stacked cover: the art over two cards fanned out behind it, the look of
/// Home's Now Playing card and the full player.
struct CxStackedArt: View {
    let itemId: String?
    let size: CGFloat

    var body: some View {
        let step = size * 0.08
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.08).fill(Color(dark: 0x4A3A4E, light: 0xC9B8CC))
                .frame(width: size * 0.9, height: size * 0.9).offset(x: step * 2, y: step * 2)
            RoundedRectangle(cornerRadius: size * 0.08).fill(Color(dark: 0x2E5A55, light: 0xA9CCC6))
                .frame(width: size * 0.95, height: size * 0.95).offset(x: step, y: step)
            ArtworkView(itemId: itemId, size: size)
                .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
        }
        .frame(width: size + step * 2, height: size + step * 2, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// A horizontal shelf of covers under a section title (Recently added, Playlists).
struct CxShelf<Item: Identifiable, Tile: View>: View {
    let title: String
    var more: AppRoute?
    let items: [Item]
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).cx(.section).foregroundStyle(Cx.text)
                Spacer()
                if let more {
                    NavigationLink(value: more) { Text("See all").cx(.row).foregroundStyle(Cx.accent) }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) { ForEach(items) { tile($0) } }
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// A cover with its name and a quiet line under it, for shelves.
struct CxCoverTile: View {
    let itemId: String?
    let title: String
    var subtitle: String?
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(itemId: itemId, size: size)
            Text(title).cx(.row).foregroundStyle(Cx.text).lineLimit(1).padding(.top, 8)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).cx(.small).foregroundStyle(Cx.text3).lineLimit(1).padding(.top, 2)
            }
        }
        // Pinned to the art: a horizontal ScrollView offers unlimited width, so a long
        // title would otherwise widen its tile.
        .frame(width: size, alignment: .leading)
    }
}

/// A section's title with an optional "See all" link at the right, at the phone's margins.
struct CxShelfTitle: View {
    let title: String
    var more: AppRoute?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).cx(.section).foregroundStyle(Cx.text)
            Spacer()
            if let more {
                NavigationLink(value: more) { Text("See all").cx(.row).foregroundStyle(Cx.accent) }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

#if os(iOS)
/// Home's card for what is playing (Penpot "iPhone / Home"): the stacked cover, a caps
/// "Now playing", the song, its artist, what comes next, and an accent play button.
struct NowPlayingCard: View {
    let player: PlaybackService

    private var upNext: String? {
        let next = player.queue.items.dropFirst(player.queue.index + 1).prefix(2).compactMap(\.name)
        return next.isEmpty ? nil : "Up next: " + next.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            CxStackedArt(itemId: player.item?.albumId ?? player.item?.id, size: 120)
            VStack(alignment: .leading, spacing: 4) {
                Text("Now playing").cx(.caps).foregroundStyle(Cx.accent)
                Text(player.item?.name ?? "").font(.display(21)).foregroundStyle(Cx.text).lineLimit(2)
                Text(player.item?.songArtist ?? "").cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                if let upNext { Text(upNext).cx(.small).foregroundStyle(Cx.text3).lineLimit(2) }
                HStack {
                    Spacer()
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Cx.ink)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 48, height: 48)
                            .background(Cx.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Cx.surface2, Cx.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Cx.line))
    }
}
#endif

#if os(iOS)
/// The phone's header for an album, artist, playlist or genre (Penpot "iPhone / Album"): the
/// art centered over a wash in its own color, the title, a meta line (with the artist as a
/// link), the voice line, the two wide buttons, then the quieter icons.
struct CxPhoneDetailHeader<Buttons: View, Icons: View>: View {
    let title: String
    let artId: String?
    var round = false
    var lead: String?
    var leadId: String?
    var meta = ""
    var voice: String?
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var icons: Icons

    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme
    @State private var tint: Color?

    var body: some View {
        VStack(spacing: 0) {
            ArtworkView(itemId: artId, size: 200)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(Rectangle()))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            Text(title).cx(.hero).foregroundStyle(Cx.text)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                .padding(.top, 20)
            HStack(spacing: 0) {
                if let lead, !lead.isEmpty {
                    ArtistLink(name: lead, id: leadId)
                    if !meta.isEmpty { Text(" \u{00B7} ") }
                }
                Text(meta)
            }
            .cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
            .padding(.top, 6)
            if let voice, !voice.isEmpty {
                Text(voice).cx(.voice).foregroundStyle(Cx.accent).multilineTextAlignment(.center).padding(.top, 6)
            }
            HStack(spacing: 12) { buttons }.padding(.top, 20)
            HStack(spacing: 20) { icons }.padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        .background(alignment: .top) {
            LinearGradient(colors: [(tint ?? Cx.accentDeep).opacity(scheme == .dark ? 0.45 : 0.22), .clear],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -200).padding(.bottom, -40)
                .allowsHitTesting(false)
        }
        .task(id: artId) {
            guard let artId, let client = state.client else { return }
            let colors = await CoverPalettes.palette(for: artId, client: client)
            guard let c = colors.max(by: { $0.chroma < $1.chroma }) else { return }
            withAnimation(.easeOut(duration: 0.3)) { tint = Color(red: c.r / 255, green: c.g / 255, blue: c.b / 255) }
        }
    }
}
#endif
