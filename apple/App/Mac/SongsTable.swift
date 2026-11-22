import SwiftUI
import CascadeKit

// The Mac's Songs screen: a virtualized Table with sortable columns, in place
// of the phone's list. SongsView owns the loading, the persisted sort and
// Play / Shuffle All; this is only how that list is drawn.

extension JfItem {
    // Table sorts by key path, and the key must be Comparable. The table never
    // sorts the rows itself (the server does, see SongsView); these are only
    // what its column headers report a click on. Dates compare as their ISO
    // text, which orders the same as the dates do.
    var songTitle: String { name ?? "" }
    var songArtist: String { albumArtist ?? artists?.first ?? "" }
    var songAlbum: String { album ?? "" }
    var songAdded: String { dateCreated ?? "" }
    var songPlayed: String { userData?.lastPlayedDate ?? "" }
}

private extension SongSortField {
    var keyPath: PartialKeyPath<JfItem> {
        switch self {
        case .name: \JfItem.songTitle
        case .artist: \JfItem.songArtist
        case .album: \JfItem.songAlbum
        case .added: \JfItem.songAdded
        case .played: \JfItem.songPlayed
        }
    }

    /// The header's own sort state for this field and direction.
    func comparator(_ direction: SortDirection) -> KeyPathComparator<JfItem> {
        let order: SortOrder = direction == .descending ? .reverse : .forward
        switch self {
        case .name: return KeyPathComparator(\.songTitle, order: order)
        case .artist: return KeyPathComparator(\.songArtist, order: order)
        case .album: return KeyPathComparator(\.songAlbum, order: order)
        case .added: return KeyPathComparator(\.songAdded, order: order)
        case .played: return KeyPathComparator(\.songPlayed, order: order)
        }
    }

    init?(keyPath: PartialKeyPath<JfItem>) {
        guard let field = Self.allCases.first(where: { $0.keyPath == keyPath }) else { return nil }
        self = field
    }
}

// Only read on the main actor, from view bodies.
nonisolated(unsafe) private let isoDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
nonisolated(unsafe) private let isoDateWhole = ISO8601DateFormatter()

/// Jellyfin writes dates with seven fractional digits; the formatter takes
/// either that form or the whole-second one.
private func shortDate(_ iso: String?) -> String {
    guard let iso, let date = isoDate.date(from: iso) ?? isoDateWhole.date(from: iso) else { return "" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

extension SongsView {
    /// Personality v1 (the Penpot "Mac / Songs" board): the page header with its voice line,
    /// sort, Play and Shuffle, the filter chips, then the table on the page's background.
    @MainActor var macContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            CxPageHeader(title: "Songs", voice: songsVoice) {
                SortMenu(fields: [(SongSortField.name, "Title"), (.artist, "Artist"), (.album, "Album"),
                                  (.added, "Date Added"), (.played, "Date Last Played")],
                         field: Binding(get: { sortField }, set: { sortField = $0; sortDirection = $0.defaultDirection }),
                         direction: Binding(get: { sortDirection }, set: { sortDirection = $0 }), chip: true)
                PillButton("Play", symbol: "play.fill", primary: true) { Task { await playAll(shuffled: false) } }
                PillButton("Shuffle", symbol: "shuffle") { Task { await playAll(shuffled: true) } }
            } below: {
                FilterChips(filter: $filter, itemType: "Audio")
            }
            .disabled(isStarting)
            .cxPage(bottom: 0)
            if items.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true, skeleton: .rows)
                    .frame(maxHeight: .infinity)
            } else {
                SongsTable(items: items, field: Binding(get: { sortField }, set: { sortField = $0 }),
                           direction: Binding(get: { sortDirection }, set: { sortDirection = $0 }))
                    // A new table per order. Handed a re-sorted list, SwiftUI's
                    // Table moves every row, and AppKit then builds and measures
                    // a row view for all of them, not just the visible ones:
                    // 1,200 songs held the main thread for about 45 seconds.
                    .id("\(sortField.rawValue)|\(sortDirection)")
                    .padding(.horizontal, 24)
            }
        }
    }

    /// Flutter's "4,212 songs, 11d 6h of music", once every page is in. Before that, how
    /// many have loaded, so the page does not claim a total it has not seen.
    @MainActor private var songsVoice: String? {
        guard !items.isEmpty else { return nil }
        guard loadedAll else { return "\(cxCount(items.count, "song")) so far\u{2026}" }
        let total = items.reduce(0.0) { $0 + ($1.runTimeTicks.map(seconds(fromTicks:)) ?? 0) }
        return "\(cxCount(items.count, "song")), \(QueueMeta.formatSpan(total)) of music"
    }
}

private struct SongsTable: View {
    let items: [JfItem]
    @Binding var field: SongSortField
    @Binding var direction: SortDirection

    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var uiScale
    @State private var selection = Set<JfItem.ID>()
    @State private var order: [KeyPathComparator<JfItem>] = []

    var body: some View {
        // Read here, not in the cells: Font.cxBody reads MacTheme, and an observation made inside a
        // Table cell (built outside this view's graph on macOS 27) crashed the app in AttributeGraph
        // when Songs was left for another page.
        let font = Font.cxBody(13 * uiScale)
        Table(items, selection: $selection, sortOrder: $order) {
            TableColumn("") { track in
                cell(track, font) { PlayingIndicator(itemId: track.id) }
            }
            .width(24)
            TableColumn("Title", value: \.songTitle) { track in
                cell(track, font) {
                    HStack(spacing: 8) {
                        ArtworkView(itemId: track.albumId ?? track.id, size: 32)
                        Text(track.songTitle).lineLimit(1).explicitMark(track.id)
                    }
                }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Artist", value: \.songArtist) { track in
                cell(track, font) { Text(track.songArtist).lineLimit(1).foregroundStyle(.secondary) }
            }
            .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.songAlbum) { track in
                cell(track, font) { Text(track.songAlbum).lineLimit(1).foregroundStyle(.secondary) }
            }
            .width(min: 100, ideal: 200)
            TableColumn("Date Added", value: \.songAdded) { track in
                cell(track, font) { Text(shortDate(track.dateCreated)).foregroundStyle(.tertiary) }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Last Played", value: \.songPlayed) { track in
                cell(track, font) { Text(shortDate(track.userData?.lastPlayedDate)).foregroundStyle(.tertiary) }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Time") { track in
                cell(track, font) {
                    Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "")
                        .monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .width(52)
        }
        // On the page's background, as the Penpot board, not the system's table color.
        .scrollContentBackground(.hidden)
        .onAppear { order = [field.comparator(direction)] }
        // Header clicks and the toolbar's menu are the same setting. Each side
        // only writes when it differs, so neither echoes the other back.
        .onChange(of: order) {
            guard let first = order.first, let clicked = SongSortField(keyPath: first.keyPath) else { return }
            let clickedDirection: SortDirection = first.order == .reverse ? .descending : .ascending
            if clicked != field { field = clicked }
            if clickedDirection != direction { direction = clickedDirection }
        }
        .onChange(of: field) { syncOrder() }
        .onChange(of: direction) { syncOrder() }
        // Acts on the selection when the clicked row is in it, on that row
        // alone otherwise (the system decides which set `ids` is).
        .contextMenu(forSelectionType: JfItem.ID.self) { ids in
            MacTracksMenu(tracks: items.filter { ids.contains($0.id) })
                .environment(state)
        }
        .trackActionHost()
        // Return plays what is selected, like double-clicking.
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            play(selected: selection, startingAt: nil)
            return .handled
        }
    }

    private func syncOrder() {
        let want = field.comparator(direction)
        if order.first != want { order = [want] }
    }

    /// One cell's content, filling the cell so the whole row answers a
    /// double-click, not only the text. The right-click menu is the table's
    /// own (above), which knows the selection.
    private func cell<Content: View>(_ track: JfItem, _ font: Font, @ViewBuilder _ content: () -> Content) -> some View {
        // Handed down explicitly: Table builds its cells outside this view's
        // environment on macOS 27, so ArtworkView and PlayingIndicator found
        // no AppState and the app stopped on a fatal error opening Songs.
        content()
            .environment(state)
            .environment(\.uiScale, uiScale)
            .font(font)
            // The desktop's row: 45 pt with a 32 pt cover (SONG_ROW_H in
            // renderer.js), not the table's default single tight line.
            .frame(maxWidth: .infinity, minHeight: 37 * uiScale, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { play(selected: [track.id], startingAt: track) })
    }

    /// Several selected: just those, in list order. One (or a double-click on
    /// an unselected row): the list on from that song, as every track list does.
    private func play(selected ids: Set<JfItem.ID>, startingAt track: JfItem?) {
        let chosen = items.filter { ids.contains($0.id) }
        Task {
            if chosen.count > 1 {
                await state.player?.play(chosen)
            } else if let track = track ?? chosen.first, let index = items.firstIndex(of: track) {
                await state.player?.play(items, startIndex: index)
            }
        }
    }
}
