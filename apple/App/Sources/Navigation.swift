import SwiftUI
import CascadeKit

/// Screens that are not a library item.
enum AppRoute: Hashable {
    case search, settings, genres, history, downloads
    /// A downloaded album or playlist, by id.
    case downloaded(String)
    /// "favorites", "most-played", or a user smart playlist's id.
    case smartPlaylist(String)
}

/// Where tapping an album, artist or playlist goes, decided by its type.
struct ItemDestination: View {
    let item: JfItem

    var body: some View {
        switch item.type {
        case "MusicArtist": ArtistDetailView(artist: item)
        case "Playlist": PlaylistDetailView(playlist: item)
        case "MusicGenre": GenreDetailView(genre: item)
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
                case .genres: GenresView()
                case .history: HistoryView()
                case .smartPlaylist(let kind): SmartPlaylistView(kind: kind)
                #if os(iOS)
                case .downloads: DownloadsView()
                case .downloaded(let id): DownloadedCollectionView(id: id)
                #else
                case .downloads, .downloaded: EmptyView()
                #endif
                }
            }
    }

    /// iOS: search and settings sit top right on every tab's root rather than
    /// taking tabs of their own, so the five library tabs never overflow into
    /// "More". tvOS keeps them as tabs, where the bar has room.
    @ViewBuilder
    func libraryToolbar() -> some View {
        #if os(iOS)
        modifier(LibraryToolbar())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Search, other devices and Settings, on every tab. Devices is here and not
/// only in Now Playing, which can only be opened while something plays here:
/// the moment you want to drive another device is often when nothing does.
private struct LibraryToolbar: ViewModifier {
    @Environment(AppState.self) private var state
    @State private var controllingDevices = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink(value: AppRoute.search) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")
                    // Here rather than in Settings: it is where you go when
                    // the server cannot be reached, and every tab has it.
                    NavigationLink(value: AppRoute.downloads) {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Downloads")
                    Button { controllingDevices = true } label: {
                        Image(systemName: state.controlledDevice == nil ? "hifispeaker.2" : "hifispeaker.2.fill")
                    }
                    .accessibilityLabel("Control Devices")
                    NavigationLink(value: AppRoute.settings) {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $controllingDevices) { DevicesSheet().environment(state) }
    }
}
#endif

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
               sortBy: String? = nil,
               sortOrder: String? = nil,
               nextStart: ((Int) -> Void)? = nil,
               fetch: (_ limit: Int, _ startIndex: Int) async throws -> [JfItem],
               apply: ([JfItem]) -> Void) async throws {
    var all: [JfItem] = []
    var seen = Set<String>()
    var libraries = Set<Int>()
    var start = 0
    while !Task.isCancelled {
        let fresh = try await fetch(pageSize, start).filter { seen.insert($0.id).inserted }
        if fresh.isEmpty { break }
        all += fresh
        libraries.formUnion(fresh.map { $0.sourceLibrary ?? -1 })
        if libraries.count <= 1 {
            // One library: the server's pages already arrive in order and
            // without copies, so there is nothing to merge or sort. Re-sorting
            // the whole list on every page (localizedStandardCompare, on the
            // main actor) stalled a large library's load for seconds at a
            // time, and Play started from Songs waited behind every stall.
            apply(all)
        } else {
            // Merged over everything loaded so far, not page by page: each page
            // takes the same offset from every library, and a song sits at a
            // different offset in each, so its copies can arrive pages apart.
            // Sorted over everything too, for the same reason: a later page from
            // one library can hold items that belong ahead of this one's.
            // The order goes too: without it a Descending sort came back ascending.
            // Off the main actor, since it grows with the whole list.
            let loaded = all
            apply(await Task.detached(priority: .userInitiated) {
                sortedLikeServer(mergeLibraryCopies(loaded), sortBy: sortBy, sortOrder: sortOrder)
            }.value)
        }
        start += pageSize
        // A server offset, applied per library, so not the same thing as the
        // merged count once more than one library is selected.
        nextStart?(start)
    }
}
