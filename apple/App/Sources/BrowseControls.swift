import SwiftUI
import CascadeKit

// Controls the browsing screens share: the sort menu, and the key a screen
// reloads on.

/// Sort field, direction and (where the screen has one) a favorites filter,
/// behind one button.
///
/// Placed at the top of each screen's content rather than in the toolbar, on
/// both platforms: tvOS does not show toolbar items on these screens.
///
/// tvOS gets a dialog instead of a Menu. A Menu there takes focus but never
/// opened on select (tvOS 26.5 simulator, driven by the Siri Remote script),
/// while a confirmation dialog is a plain list of focusable buttons.
struct SortMenu<Field: Hashable>: View {
    let fields: [(Field, String)]
    @Binding var field: Field
    @Binding var direction: SortDirection
    var favoritesOnly: Binding<Bool>?
    #if os(tvOS)
    @State private var isChoosing = false
    #endif

    var body: some View {
        #if os(tvOS)
        Button { isChoosing = true } label: {
            Label(summary, systemImage: "arrow.up.arrow.down")
        }
        .confirmationDialog("Sort", isPresented: $isChoosing) {
            if fields.count > 1 {
                ForEach(fields, id: \.0) { option in
                    Button(option.0 == field ? "\(option.1) \u{2713}" : option.1) { field = option.0 }
                }
            }
            Button(direction == .ascending ? "Order: Ascending" : "Order: Descending") {
                direction = direction == .ascending ? .descending : .ascending
            }
            if let favoritesOnly {
                Button(favoritesOnly.wrappedValue ? "Favorites Only: On" : "Favorites Only: Off") {
                    favoritesOnly.wrappedValue.toggle()
                }
            }
        }
        #else
        Menu {
            // One field (Artists) needs no picker, only the direction.
            if fields.count > 1 {
                Picker("Sort By", selection: $field) {
                    ForEach(fields, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            Picker("Order", selection: $direction) {
                Text("Ascending").tag(SortDirection.ascending)
                Text("Descending").tag(SortDirection.descending)
            }
            if let favoritesOnly {
                Toggle("Favorites Only", isOn: favoritesOnly)
            }
        } label: {
            Label(summary, systemImage: "arrow.up.arrow.down")
        }
        #endif
    }

    private var summary: String {
        let name = fields.first { $0.0 == field }?.1 ?? "Sort"
        return favoritesOnly?.wrappedValue == true ? "\(name), Favorites" : name
    }
}

/// Favorites, genre, decade and played behind one button, filled in while
/// any is on: the desktop's filter dropdown. Genres and decades are the ones
/// in the selected libraries, so nothing offered comes back empty.
///
/// tvOS gets a dialog, as SortMenu does, where each press of Genre or Decade
/// steps to the next choice: a genre list is too long for a dialog of its own.
struct FilterMenu: View {
    @Binding var filter: BrowseFilter
    /// What the genre and decade lists are read from: "MusicAlbum", "Audio",
    /// "Movie" or "Series".
    let itemType: String
    var showsGenre = true
    var showsDecade = true
    var showsPlayed = true
    /// The movie or TV libraries a video filter's lists are read from. Music
    /// ones come from the library selection in the config.
    var libraryIds: [String] = []

    @Environment(AppState.self) private var state
    @State private var genres: [String] = []
    @State private var decades: [Int] = []
    #if os(tvOS)
    @State private var isChoosing = false
    #endif

    private struct ListsKey: Hashable { var music: [String]; var video: [String] }

    var body: some View {
        menu
            .task(id: ListsKey(music: state.config?.libraryIds ?? [], video: libraryIds)) {
                guard let client = state.client else { return }
                let isVideo = itemType == "Movie" || itemType == "Series"
                if showsGenre {
                    genres = (isVideo ? try? await client.genreNames(types: itemType, libraryIds: libraryIds)
                                      : try? await client.genres().compactMap(\.name)) ?? []
                }
                if showsDecade {
                    let years = isVideo ? try? await client.years(of: itemType, libraryIds: libraryIds)
                                        : try? await client.years(of: itemType)
                    decades = BrowseFilter.decades(years ?? [])
                }
            }
    }

    private var label: some View {
        Label(filter.isActive ? "Filtered" : "Filter",
              systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
    }

    #if os(tvOS)
    private var menu: some View {
        Button { isChoosing = true } label: { label }
            .confirmationDialog("Filter", isPresented: $isChoosing) {
                Button(filter.favoritesOnly ? "Favorites Only: On" : "Favorites Only: Off") { filter.favoritesOnly.toggle() }
                if !genres.isEmpty {
                    Button("Genre: \(filter.genre ?? "Any")") { filter.genre = next(filter.genre, in: genres) }
                }
                if showsDecade, !decades.isEmpty {
                    Button("Decade: \(filter.decade.map { "\(String($0))s" } ?? "Any")") {
                        filter.decade = next(filter.decade, in: decades)
                    }
                }
                if showsPlayed {
                    Button("Played: \(playedName(filter.played))") {
                        let all = BrowseFilter.Played.allCases
                        filter.played = all[(all.firstIndex(of: filter.played)! + 1) % all.count]
                    }
                }
                if filter.isActive { Button("Clear Filters", role: .destructive) { filter = .init() } }
            }
    }

    /// Any, then each choice in turn, then back to any.
    private func next<T: Equatable>(_ current: T?, in all: [T]) -> T? {
        guard let current, let i = all.firstIndex(of: current) else { return all.first }
        return i + 1 < all.count ? all[i + 1] : nil
    }
    #else
    private var menu: some View {
        Menu {
            Toggle("Favorites Only", isOn: $filter.favoritesOnly)
            if !genres.isEmpty {
                Picker("Genre", selection: $filter.genre) {
                    Text("Any Genre").tag(String?.none)
                    ForEach(genres, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            if showsDecade, !decades.isEmpty {
                Picker("Decade", selection: $filter.decade) {
                    Text("Any Decade").tag(Int?.none)
                    ForEach(decades, id: \.self) { Text("\(String($0))s").tag(Optional($0)) }
                }
                .pickerStyle(.menu)
            }
            if showsPlayed {
                Picker("Played", selection: $filter.played) {
                    ForEach(BrowseFilter.Played.allCases, id: \.self) { Text(playedName($0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if filter.isActive {
                Button("Clear Filters", systemImage: "xmark.circle", role: .destructive) { filter = .init() }
            }
        } label: {
            label
        }
    }
    #endif

    private func playedName(_ played: BrowseFilter.Played) -> String {
        switch played {
        case .any: "Played or Not"
        case .played: "Played"
        case .unplayed: "Unplayed"
        }
    }
}

/// Everything a browsing screen's list depends on. The screen's `.task(id:)`
/// is keyed on this, so changing the library selection, the sort or the filter
/// cancels a load still paging in and starts over.
struct BrowseKey: Hashable {
    var libraries: [String]?
    var sort: String
    var direction: SortDirection
    var filter = BrowseFilter()
    /// Bumped to reload after a write the screen made itself.
    var generation = 0
}

extension Binding where Value == LibraryPrefs {
    /// The sort field as a screen's own enum, over the prefs' stored string.
    /// Picking a field also sets the direction that suits it (newest first for
    /// a date), which the person can still flip back.
    func sort<F: RawRepresentable & Hashable>(_ fallback: F, defaultDirection: @escaping (F) -> SortDirection)
        -> Binding<F> where F.RawValue == String {
        Binding<F>(get: { wrappedValue.sortField(default: fallback) },
                   set: { wrappedValue.field = $0.rawValue; wrappedValue.direction = defaultDirection($0) })
    }
}

/// The browse screens whose lists AppState keeps; see AppState.browseList.
enum BrowseScreen: Hashable { case albums, artists, songs, playlists }

/// One browse screen's list as AppState loads it. Observable, so a screen
/// showing it updates as pages arrive, including the ones that arrived while
/// it was off screen.
@MainActor @Observable
final class BrowseList {
    var items: [JfItem] = []
    var isLoading = true
    var error: String?
    /// Every page is in, not just the ones so far.
    var isComplete = false
    /// The server offset of the first page not fetched yet, for screens that
    /// hand the rest of their list to the player (Songs' Play).
    var nextStart = 0
    /// Holds the whole library for its key (every page, not a recent-only
    /// or random selection), so another sort of it can be made on the device.
    var isWholeList = false
    @ObservationIgnored var task: Task<Void, Never>?
}

struct BrowseCacheKey: Hashable {
    let screen: BrowseScreen
    let key: BrowseKey
}

/// Plays a list shuffled, the way the player's own shuffle does it: a random
/// first track, then shuffle turned on around it. Playing index 0 and then
/// shuffling always started on the list's first song.
@MainActor
func playShuffled(_ items: [JfItem], on player: PlaybackService?) async {
    guard let player, !items.isEmpty else { return }
    await player.play(items, startIndex: Int.random(in: items.indices))
    player.toggleShuffle()
}

extension View {
    /// The row of controls above a browsing screen's list. On tvOS it is a
    /// focus section: its button sits at the left edge, and moving up from
    /// the grid only looks straight up, so without this focus skipped the
    /// row and landed on the tab bar.
    @ViewBuilder
    func browseHeader() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}

extension View {
    /// The alert every write failure shows. A refused write must never look
    /// like a saved one (CODEMAP rule 1), so the server's reason is shown.
    func writeErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Could not save", isPresented: Binding(get: { message.wrappedValue != nil },
                                                     set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK") {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
