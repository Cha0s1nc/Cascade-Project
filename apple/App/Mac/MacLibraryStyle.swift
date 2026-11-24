import SwiftUI
import CascadeKit

// The pieces the Mac's library pages are built from in Personality v1, as the Penpot
// "Mac / Songs", "Album", "Artist" and "Playlist" boards and Flutter's desktop pages
// (flutter/lib/ui/pages/common.dart and detail.dart): the page header with its voice
// line, filter chips, cards, and the big header an album, artist or playlist opens with.

extension View {
    /// A library page's margins, as Home's, grown with View > Zoom.
    func cxPage(top: CGFloat = 30, bottom: CGFloat = 40) -> some View { modifier(CxPageMargins(top: top, bottom: bottom)) }
}

private struct CxPageMargins: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat
    @Environment(\.uiScale) private var zoom
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36 * zoom).padding(.top, top * zoom).padding(.bottom, bottom * zoom)
    }
}

/// All, Favorites, Genre, Decade and Played as chips, bound to a screen's BrowseFilter
/// (the same stored filter the old Filter menu set).
struct FilterChips: View {
    @Binding var filter: BrowseFilter
    let itemType: String
    /// Movies and TV: the genres and years of the chosen libraries.
    var libraryIds: [String] = []
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
        .task(id: (state.config?.libraryIds ?? []) + libraryIds) {
            guard !favoritesOnly else { return }
            (genres, decades) = await FilterMenu.choices(state: state, itemType: itemType, libraryIds: libraryIds)
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

/// The header an album, artist or playlist page opens with: the art, a caps label, the
/// title, a meta line (an album's artist links), the voice line and the buttons, over a
/// wash in the cover's own color.
struct CxDetailHeader<Actions: View>: View {
    let label: String
    let title: String
    let artId: String?
    var round = false
    /// Width over height: 2/3 for a movie's or show's poster.
    var aspect: CGFloat = 1
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
            ArtworkView(itemId: artId, size: 220 * min(aspect, 1), aspect: aspect)
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

/// The hover every card shares (Flutter's Hover): `content` is drawn with whether the
/// pointer is over it, quick in and a little slower out. One place, so albums, shelves,
/// Continue watching, posters and stills all answer the pointer alike.
struct CardHover<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering || CardHover<EmptyView>.forced)
            .contentShape(Rectangle())
            .onHover { on in withAnimation(.easeOut(duration: on ? 0.12 : 0.2)) { hovering = on } }
    }
}

extension CardHover where Content == EmptyView {
    /// Debug builds: `-cascade.debugHover YES` draws every card hovered, to check the look
    /// without a pointer.
    static var forced: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "cascade.debugHover")
        #else
        false
        #endif
    }
}

/// The accent play button a card shows under the pointer (Flutter's PlayCircle).
struct CardPlayButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Cx.ink)
                .frame(width: 40, height: 40)
                .background(Cx.accent, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An album, playlist or artist card (Flutter's MediaCard): the art (round for an
/// artist), its name and a line under it. Hovering lifts the name to the accent and,
/// for anything with songs, shows a play button on the art.
struct MacTile: View {
    let item: JfItem
    var subtitle: String?
    @Environment(AppState.self) private var state

    private var isArtist: Bool { item.type == "MusicArtist" }

    var body: some View {
        CardHover { hovering in
            VStack(alignment: isArtist ? .center : .leading, spacing: 0) {
                ArtworkView(itemId: item.id, size: 160, fillsFrame: true)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(Rectangle()))
                    .shadow(color: .black.opacity(hovering && !isArtist ? 0.3 : 0), radius: 10, y: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if !isArtist && hovering {
                            CardPlayButton(help: "Play") {
                                Task { await state.player?.play(await tracksOf(item, client: state.client)) }
                            }
                            .padding(10)
                            .transition(.opacity)
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
        }
    }
}

/// A movie's or show's poster on the Mac (Flutter's posterCard): under the pointer the art
/// dims, a play button sits at its bottom left (Play or Resume for a movie, the next episode
/// for a show) and the name turns to the accent.
struct MacPosterTile: View {
    let item: JfItem
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var zoom

    private var playLabel: String {
        item.type == "Series" ? "Play next episode" : (item.userData?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play"
    }

    var body: some View {
        CardHover { hovering in
            VStack(alignment: .leading, spacing: 0) {
                ArtworkView(itemId: item.id, size: posterWidth, aspect: 2.0 / 3.0)
                    .overlay(alignment: .bottom) { WatchedBar(item: item) }
                    .overlay { ProportionalRoundedRectangle().fill(.black.opacity(hovering ? 0.55 : 0)).allowsHitTesting(false) }
                    .overlay(alignment: .bottomLeading) {
                        if hovering && (item.type == "Movie" || item.type == "Series") {
                            CardPlayButton(help: playLabel) { Task { await play() } }
                                .padding(10)
                                .transition(.opacity)
                        }
                    }
                Text(item.name ?? "Untitled").cx(.row).foregroundStyle(hovering ? Cx.accent : Cx.text)
                    .lineLimit(1).padding(.top, 8)
                if let year = item.productionYear {
                    Text(String(year)).cx(.small).foregroundStyle(Cx.text3).padding(.top, 2)
                }
            }
            .frame(width: posterWidth * zoom, alignment: .leading)
        }
    }

    /// A movie where it was left (the player resumes); a show at its next episode.
    private func play() async {
        if item.type == "Series" {
            guard let next = try? await state.client?.nextUp(seriesId: item.id, limit: 1).first else { return }
            await state.playVideoItem(next)
        } else {
            await state.playVideoItem(item)
        }
    }
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

/// Personality v1's settings cards (Flutter's SettingsGroup and SettingRow) as a Form style:
/// each section a card on the surface with a line round it, its title in caps above a rule,
/// one row per control with a rule between, and its footer as a quiet note under the card.
/// Controls keep the grouped form's layout: label at the left, control at the right.
///
/// The app-wide accent tint (MacThemed) is reset to the default here: since macOS 26 a tint
/// also colors a bordered button's label and a pop-up's value, which on these dark cards read
/// as faint accent text with no visible bezel. Without it buttons and pop-ups are the
/// system's gray ones, as in System Settings; switches and the settings sliders set the
/// accent themselves. Fields go inline with CxFieldRow, buttons at a row's end (CxButtonRow).
struct CxFormStyle: FormStyle {
    /// False for a form inside a page that already scrolls (sign-in's Advanced).
    var scrolls = true

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if scrolls {
                ScrollView {
                    sections(configuration).padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 32)
                }
            } else {
                sections(configuration)
            }
        }
        .toggleStyle(CxRowToggleStyle())
        .labeledContentStyle(CxRowLabeledContentStyle())
        .tint(nil)
    }

    private func sections(_ configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections: configuration.content) { section in
                CxFormSection(section: section)
            }
        }
    }
}

/// A text field inline in a settings row, as System Settings draws one: the label at the
/// left, the value edited in place at the right with no box, the prompt standing in while it
/// is empty, and a faint field behind it only while it has focus.
struct CxFieldRow: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var secure = false
    @FocusState private var focused: Bool

    init(_ title: String, text: Binding<String>, prompt: String = "", secure: Bool = false) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.secure = secure
    }

    var body: some View {
        LabeledContent(title) {
            Group {
                if secure {
                    SecureField(title, text: $text, prompt: Text(prompt))
                } else {
                    TextField(title, text: $text, prompt: Text(prompt))
                }
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Cx.text)
            .focused($focused)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(focused ? Cx.surface2 : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Buttons at the trailing end of their own row, as System Settings sets them ("Add Group…",
/// "Edit…"), with an optional note at the leading end (a status, a problem in red).
struct CxButtonRow<Note: View, Buttons: View>: View {
    @ViewBuilder let note: Note
    @ViewBuilder let buttons: Buttons

    var body: some View {
        // A Spacer, not a stretched note: an empty note (EmptyView, or an `if` that is false)
        // drops its frame with it and the buttons slid to the left.
        HStack(spacing: 10) {
            note.font(.cxBody(11.5))
            Spacer(minLength: 0)
            buttons
        }
    }
}

extension CxButtonRow where Note == EmptyView {
    init(@ViewBuilder buttons: () -> Buttons) {
        self.note = EmptyView()
        self.buttons = buttons()
    }
}

/// A row's label: its first line as the title, any further lines as the description under
/// it in text 3, as the system's grouped form stacks them. In a plain HStack the lines
/// would sit side by side, the description as a squeezed middle column.
private struct CxRowLabel<Label: View>: View {
    let label: Label
    @Environment(\.uiScale) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group(subviews: label) { lines in
                if let first = lines.first { first }
                ForEach(lines.dropFirst()) { line in
                    line.font(.cxBody(11.5 * zoom)).foregroundStyle(Cx.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CxFormSection: View {
    let section: SectionConfiguration
    @Environment(\.uiScale) private var zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if !section.header.isEmpty {
                    section.header
                        .font(.cxBody(11 * zoom, .semibold)).tracking(0.66 * zoom).textCase(.uppercase)
                        .foregroundStyle(Cx.text3)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Cx.line.frame(height: 1)
                }
                Group(subviews: section.content) { rows in
                    ForEach(rows) { row in
                        row
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        if row.id != rows.last?.id { Cx.line.frame(height: 1) }
                    }
                }
            }
            .background(Cx.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Cx.line))
            if !section.footer.isEmpty {
                section.footer
                    .font(.cxBody(11 * zoom)).foregroundStyle(Cx.text3)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A switch row: the label (and any description under it) at the left, the switch at the right.
private struct CxRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            CxRowLabel(label: configuration.label)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .tint(Cx.accent)
        }
    }
}

/// LabeledContent in a settings row: the label at the left, its value or control at the right.
private struct CxRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            CxRowLabel(label: configuration.label)
            configuration.content.foregroundStyle(Cx.text2)
        }
    }
}
