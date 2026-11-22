import SwiftUI
import CascadeKit

/// Everything this user has played, newest first and grouped by day: the
/// desktop's History view. Tapping a song plays on through the rest of the
/// history from there, not just that day.
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        #if os(macOS)
        macBody
        #else
        listBody
        #endif
    }

    #if os(macOS)
    /// Personality v1, as Flutter's HistoryPage: the page header, then each day's title over
    /// the album page's track rows, numbered through the whole history.
    private var macBody: some View {
        let days = PlayHistory.byDay(items)
        let position = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CxPageHeader(title: "History", voice: "What you played, newest first.") {} below: {}
                ForEach(Array(days.enumerated()), id: \.element.id) { k, day in
                    CxSectionTitle(title: day.label, top: k == 0 ? 0 : 24)
                    ForEach(day.items) { track in
                        let index = position[track.id] ?? 0
                        CxTrackRow(track: track, number: index + 1, showsArt: true,
                                   second: [track.albumArtist ?? track.artists?.first, track.album]
                                       .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")) {
                            // The flat list's index, so play continues past this day.
                            Task { await state.player?.play(items, startIndex: index) }
                        }
                    }
                }
                if items.isEmpty {
                    LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true, emptySymbol: "clock", skeleton: .rows,
                                   emptyTitle: "Nothing played yet",
                                   emptyMessage: "Songs you play show up here.", retry: { Task { await load() } })
                }
            }
            .cxPage()
        }
        .navigationTitle("History")
        .task { await load() }
    }
    #endif

    private var listBody: some View {
        let days = PlayHistory.byDay(items)
        return List {
            ForEach(days) { day in
                Section(day.label) {
                    ForEach(day.items) { track in
                        Button {
                            // The flat list's index, so play continues past this day.
                            let index = items.firstIndex { $0.id == track.id } ?? 0
                            Task { await state.player?.play(items, startIndex: index) }
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                        .trackContextMenu(track)
                    }
                }
            }
            if items.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true, emptySymbol: "clock", skeleton: .rows,
                               emptyTitle: "Nothing played yet",
                               emptyMessage: "Songs you play show up here.", retry: { Task { await load() } })
            }
        }
        .navigationTitle("History")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = state.client else { return }
        state.snapshotHistory()
        do {
            items = try await client.playHistory()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
