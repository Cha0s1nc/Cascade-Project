import SwiftUI
import CascadeKit

/// Screens that are not a library item.
enum AppRoute: Hashable {
    case search, settings
}

/// Where tapping an album, artist or playlist goes, decided by its type.
struct ItemDestination: View {
    let item: JfItem

    var body: some View {
        switch item.type {
        case "MusicArtist": ArtistDetailView(artist: item)
        case "Playlist": PlaylistDetailView(playlist: item)
        default: AlbumDetailView(album: item)
        }
    }
}

extension View {
    /// Every tab's stack routes the same way, declared once at its root.
    ///
    /// Each screen used to push its own detail with
    /// `navigationDestination(isPresented:)`, and an artist page pushed an
    /// album the same way from inside that. Stacked like that, SwiftUI could
    /// show two back buttons. Values and one destination per type cannot.
    func appNavigation() -> some View {
        navigationDestination(for: JfItem.self) { ItemDestination(item: $0) }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .search: SearchView()
                case .settings: SettingsView()
                }
            }
    }

    /// iOS: search and settings sit top right on every tab's root rather than
    /// taking tabs of their own, so the five library tabs never overflow into
    /// "More". tvOS keeps them as tabs, where the bar has room.
    @ViewBuilder
    func libraryToolbar() -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: AppRoute.search) {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
                NavigationLink(value: AppRoute.settings) {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("Settings")
            }
        }
        #else
        self
        #endif
    }
}

/// Playlists played from, most recent first, for Home's row. Kept on the
/// device: Jellyfin records plays per track, not per playlist.
enum RecentPlaylists {
    private static let key = "cascade.recentPlaylists"
    private static let cap = 20

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func touch(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(cap)), forKey: key)
    }

    /// `playlists` with the recently played ones first, in play order.
    static func ordered(_ playlists: [JfItem]) -> [JfItem] {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return playlists.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }
}

/// Loads a long list a page at a time. The first page shows as soon as it
/// arrives and the rest streams in behind it; before this, Songs and Albums
/// waited for one 500-item request and silently stopped there (1,449 songs
/// and 944 albums on the server, 500 of each shown).
@MainActor
func loadPaged(pageSize: Int = 200,
               fetch: (_ limit: Int, _ startIndex: Int) async throws -> [JfItem],
               apply: ([JfItem]) -> Void) async throws {
    var all: [JfItem] = []
    var seen = Set<String>()
    var start = 0
    while !Task.isCancelled {
        let fresh = try await fetch(pageSize, start).filter { seen.insert($0.id).inserted }
        if fresh.isEmpty { break }
        all += fresh
        // Merged over everything loaded so far, not page by page: each page
        // takes the same offset from every library, and a song sits at a
        // different offset in each, so its copies can arrive pages apart.
        apply(mergeLibraryCopies(all))
        start += pageSize
    }
}
