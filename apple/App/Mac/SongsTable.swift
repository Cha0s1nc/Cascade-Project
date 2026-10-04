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
    @MainActor var macContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { Task { await playAll(shuffled: false) } } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button { Task { await playAll(shuffled: true) } } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                }
                Spacer()
                if isLoading || !items.isEmpty {
                    Text(items.count == 1 ? "1 song" : "\(items.count.formatted()) songs")
                        .font(.callout).foregroundStyle(.secondary)
                    if !loadedAll { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .disabled(isStarting)
            Divider()
            if items.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true)
                    .frame(maxHeight: .infinity)
            } else {
                SongsTable(items: items, field: Binding(get: { sortField }, set: { sortField = $0 }),
                           direction: Binding(get: { sortDirection }, set: { sortDirection = $0 }))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                sortMenu
                FilterMenu(filter: $filter, itemType: "Audio")
            }
        }
    }
}

private struct SongsTable: View {
    let items: [JfItem]
    @Binding var field: SongSortField
    @Binding var direction: SortDirection

    @Environment(AppState.self) private var state
    @State private var selection = Set<JfItem.ID>()
    @State private var order: [KeyPathComparator<JfItem>] = []

    var body: some View {
        Table(items, selection: $selection, sortOrder: $order) {
            TableColumn("") { track in
                cell(track) { PlayingIndicator(itemId: track.id) }
            }
            .width(24)
            TableColumn("Title", value: \.songTitle) { track in
                cell(track) {
                    HStack(spacing: 8) {
                        ArtworkView(itemId: track.albumId ?? track.id, size: 24)
                        Text(track.songTitle).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Artist", value: \.songArtist) { track in
                cell(track) { Text(track.songArtist).lineLimit(1).foregroundStyle(.secondary) }
            }
            .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.songAlbum) { track in
                cell(track) { Text(track.songAlbum).lineLimit(1).foregroundStyle(.secondary) }
            }
            .width(min: 100, ideal: 200)
            TableColumn("Date Added", value: \.songAdded) { track in
                cell(track) { Text(shortDate(track.dateCreated)).foregroundStyle(.secondary) }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Last Played", value: \.songPlayed) { track in
                cell(track) { Text(shortDate(track.userData?.lastPlayedDate)).foregroundStyle(.secondary) }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Time") { track in
                cell(track) {
                    Text(track.runTimeTicks.map { clock(seconds(fromTicks: $0)) } ?? "")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(52)
        }
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
    /// double-click and a right-click, not only the text. The menu is the
    /// shared track menu, so it is the same as every other track list's.
    private func cell<Content: View>(_ track: JfItem, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .trackContextMenu(track)
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
