import SwiftUI
import CascadeKit

#if os(iOS)
/// The iPhone's Library tab (Penpot "iPhone / Library"): the title and its voice line over
/// one card of rows, each opening a library page. Radio and Rediscover from the board are
/// not here until the iPhone has them.
struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var counts: ItemCounts?

    private struct Row: Identifiable {
        let title: String
        let symbol: String
        let route: AppRoute
        var count: Int?
        var id: String { title }
    }

    private var rows: [Row] {
        [
            Row(title: "Albums", symbol: "opticaldisc", route: .albums, count: counts?.albumCount),
            Row(title: "Artists", symbol: "person", route: .artists, count: counts?.artistCount),
            Row(title: "Songs", symbol: "music.note", route: .songs, count: counts?.songCount),
            Row(title: "Playlists", symbol: "music.note.list", route: .playlists),
            Row(title: "Genres", symbol: "square.grid.2x2", route: .genres),
            Row(title: "History", symbol: "clock", route: .history),
            Row(title: "Downloads", symbol: "arrow.down.to.line", route: .downloads),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxPageHeader(title: "Library", voice: voice) { EmptyView() } below: { EmptyView() }
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        NavigationLink(value: row.route) { RowLabel(row: row) }
                            .buttonStyle(.plain)
                        if row.id != rows.last?.id {
                            Cx.line.frame(height: 1).padding(.leading, 50)
                        }
                    }
                }
                .background(Cx.surface, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Cx.bg)
        // The page draws its own big title; the bar keeps the name for the Back button.
        .navigationTitle("Library")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text("") } }
        .task(id: state.isOffline) {
            guard !state.isOffline else { counts = nil; return }
            counts = try? await state.client?.itemCounts()
        }
    }

    /// The board's line, once the server has said how many songs there are.
    private var voice: String? {
        guard let songs = counts?.songCount, songs > 0 else { return nil }
        return "\(cxCount(songs, "song")), and every one is yours."
    }

    private struct RowLabel: View {
        let row: Row

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: row.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Cx.accent)
                    .frame(width: 22)
                Text(row.title).cx(.strong).foregroundStyle(Cx.text)
                Spacer(minLength: 8)
                if let count = row.count {
                    Text(count.formatted()).cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Cx.text3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
    }
}
#endif
