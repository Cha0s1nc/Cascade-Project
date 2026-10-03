import SwiftUI
import CascadeKit

// Video's Home and the movie and show grids. Pages for one movie or show, and
// the player, are in VideoViews.swift and VideoPlayer.swift.

/// "Good morning, name", the desktop's Home heading (renderer.js greeting).
struct GreetingHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        Text("\(part), \(state.username ?? "there")")
            .font(.largeTitle.bold())
            .padding(.horizontal)
    }
}

/// Video's Home: pick up where you left off, one card per show, and what is new.
struct VideoHomeView: View {
    @Environment(AppState.self) private var state
    @State private var resume: [JfItem] = []
    @State private var movies: [JfItem] = []
    @State private var episodes: [JfItem] = []
    @State private var loaded = false
    @State private var error: String?

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private struct LoadKey: Hashable { var movies: [String]; var shows: [String]; var revision: Int }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if os(macOS)
                GreetingHeader()
                #endif
                if !resume.isEmpty { stills("Continue Watching", resume) }
                if !movies.isEmpty { posters("Recently Added Movies", movies) }
                if !episodes.isEmpty { stills("Recently Added Episodes", episodes) }
                if loaded, resume.isEmpty, movies.isEmpty, episodes.isEmpty {
                    ContentUnavailableView("No Videos", systemImage: "film",
                                           description: Text(error ?? emptyReason))
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .refreshable { await load() }
        // Reloads when the library choice changes, and after a video closes
        // (its stopped report has landed by then, so resume points are real).
        .task(id: LoadKey(movies: libraries.movieIds, shows: libraries.showIds, revision: state.videoRevision)) {
            await load()
        }
    }

    private var emptyReason: String {
        libraries.isLoaded && !libraries.hasVideoLibrary
            ? "This server has no movie or TV library you can see."
            : "Nothing to show from the libraries chosen in Settings."
    }

    private func load() async {
        guard let client = state.client else { return }
        await libraries.load(client: client, userId: state.config?.userId)
        let (movieIds, showIds) = (libraries.movieIds, libraries.showIds)
        do {
            // A kind with no library chosen is not asked about at all: the
            // desktop skips those queries too, and an unscoped one would
            // return the libraries the person deselected.
            async let r = movieIds.isEmpty && showIds.isEmpty
                ? [] : client.continueWatchingMerged(movieIds: movieIds, showIds: showIds)
            async let m = movieIds.isEmpty ? [] : client.latestVideo("Movie", libraryIds: movieIds)
            async let e = showIds.isEmpty ? [] : client.latestVideo("Episode", libraryIds: showIds)
            (resume, movies, episodes) = try await (r, m, e)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func stills(_ title: String, _ items: [JfItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { VideoStillTile(item: $0) }
                }
                .padding(.horizontal)
            }
        }
    }

    private func posters(_ title: String, _ items: [JfItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { PosterTile(item: $0) }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// All movies or all shows, as a poster grid: one flat grid for a single
/// library, one collapsible group per library when several are chosen (the
/// desktop's grouped poster grid). Sort and filter are remembered per kind in
/// the desktop's shape (cascade.moviesPrefs, cascade.showsPrefs).
struct VideoGridView: View {
    enum Kind { case movies, shows }
    let kind: Kind
    @Environment(AppState.self) private var state
    @AppStorage private var prefs: LibraryPrefs
    /// A JSON array of library ids, as the desktop keeps it.
    @AppStorage("cascade.collapsedLibs") private var collapsedStored = "[]"
    @State private var groups: [VideoGroup] = []
    @State private var loading = true
    @State private var error: String?
    /// Bumped by pull to refresh and by a random re-draw.
    @State private var refreshes = 0

    init(kind: Kind) {
        self.kind = kind
        _prefs = AppStorage(wrappedValue: LibraryPrefs(), kind == .movies ? "cascade.moviesPrefs" : "cascade.showsPrefs")
    }

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private var ids: [String] { kind == .movies ? libraries.movieIds : libraries.showIds }
    private var allLibraries: [JfItem] { kind == .movies ? libraries.movieLibraries : libraries.showLibraries }
    private var itemType: String { kind == .movies ? "Movie" : "Series" }
    private var sortField: VideoSortField { prefs.sortField(default: .name) }
    private var collapsed: Set<String> { CollapsedLibraries.decode(collapsedStored) }

    private struct LoadKey: Hashable {
        var ids: [String]; var field: VideoSortField; var direction: SortDirection
        var filter: BrowseFilter; var refreshes: Int
    }

    var body: some View {
        ScrollView {
            #if !os(macOS)
            HStack { controls; Spacer() }
                .padding(.horizontal)
                .browseHeader()
            #endif
            VStack(alignment: .leading, spacing: 8) {
                if groups.count > 1 {
                    ForEach(groups) { group in groupView(group) }
                } else if let only = groups.first, !only.items.isEmpty {
                    grid(only.items)
                }
            }
            if groups.allSatisfy({ $0.items.isEmpty }) {
                LoadingOverlay(isLoading: loading, error: error, isEmpty: !loading && error == nil)
                    .padding(.top, 40)
                if !loading, error == nil { Text(emptyReason).foregroundStyle(.secondary).padding() }
            }
        }
        .navigationTitle(kind == .movies ? "Movies" : "Shows")
        #if os(macOS)
        .toolbar { ToolbarItemGroup { controls } }
        #endif
        .refreshable { refreshes += 1 }
        .task(id: LoadKey(ids: ids, field: sortField, direction: prefs.direction,
                          filter: prefs.filter, refreshes: refreshes)) { await load() }
    }

    private var emptyReason: String {
        if !libraries.isLoaded { return "" }
        if allLibraries.isEmpty { return "This server has no \(kind == .movies ? "movie" : "TV") library you can see." }
        if ids.isEmpty { return "No \(kind == .movies ? "movie" : "TV") library is chosen. Choose one in Settings." }
        return prefs.filter.isActive ? "Nothing matches these filters." : "Nothing here yet."
    }

    @ViewBuilder private var controls: some View {
        SortMenu(fields: [(VideoSortField.name, "Name"), (.year, "Year"), (.added, "Date Added"), (.random, "Random")],
                 field: $prefs.sort(.name) { $0.defaultDirection }, direction: $prefs.direction)
        FilterMenu(filter: $prefs.filter, itemType: itemType, libraryIds: ids)
    }

    private func grid(_ items: [JfItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 16)], spacing: 20) {
            ForEach(items) { PosterTile(item: $0) }
        }
        .padding()
    }

    /// One library's header (name and count) over its posters. The posters are
    /// loaded either way, so expanding never refetches.
    private func groupView(_ group: VideoGroup) -> some View {
        let isCollapsed = collapsed.contains(group.libraryId)
        let name = allLibraries.first { $0.id == group.libraryId }?.name ?? group.libraryId
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                var now = collapsed
                if isCollapsed { now.remove(group.libraryId) } else { now.insert(group.libraryId) }
                collapsedStored = CollapsedLibraries.encode(now)
            } label: {
                HStack {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .font(.caption.weight(.bold))
                        .frame(width: 14)
                    Text(name).font(.title3.bold())
                    Text("\(group.items.count)").foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(group.items.count)")
            .accessibilityHint(isCollapsed ? "Expand" : "Collapse")
            if !isCollapsed { grid(group.items) }
        }
    }

    private func load() async {
        guard let client = state.client else { return }
        await libraries.load(client: client, userId: state.config?.userId)
        let ids = self.ids
        // No library chosen shows nothing rather than everything: an unscoped
        // query would return the libraries the person turned off.
        guard !ids.isEmpty else {
            groups = []
            loading = false
            return
        }
        loading = true
        do {
            let found = try await client.videoGroups(type: itemType, libraryIds: ids,
                                                     sortBy: sortField.serverSortBy,
                                                     sortOrder: prefs.direction.serverValue, filter: prefs.filter)
            groups = sortField == .random ? found.map { VideoGroup(libraryId: $0.libraryId, items: $0.items.shuffled()) } : found
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }
}
