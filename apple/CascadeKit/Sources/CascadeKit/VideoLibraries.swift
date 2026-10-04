import Foundation

// Movie and TV library selection, and the video queries scoped to it. Ported
// from the desktop's src/core/jellyfin.ts (splitVideoLibraryIds,
// effectiveLibraryIds, onePerSeries).
//
// Deliberately a selection of its own rather than widening the music one:
// `ServerConfig.libraryIds` narrows every music query, so folding movie
// libraries into it would make every album and artist query fan out across
// them. Movies and TV are kept apart from each other for the same reason.

public enum VideoLibraries {
    /// Library collection types by kind.
    public static let movieType = "movies"
    public static let showType = "tvshows"

    /// One-time migration: earlier builds saved movie and TV libraries
    /// together in one flat list. Splits it by each id's CollectionType; an
    /// id that no longer matches anything is dropped rather than guessed at.
    public static func split(libs: [JfItem], oldIds: [String]) -> (movieIds: [String], showIds: [String]) {
        func ids(_ type: String) -> [String] {
            oldIds.filter { id in libs.contains { $0.id == id && $0.collectionType == type } }
        }
        return (ids(movieType), ids(showType))
    }

    /// The ids in effect for one category. With exactly one library there is
    /// nothing to choose, so it defaults on when nothing was ever chosen
    /// (`saved == nil`), but an explicit empty choice sticks as off. Saved ids
    /// that no longer name a library of this category are dropped.
    ///
    /// Never chosen with several libraries selects nothing here, as on the
    /// desktop; `selection` below decides what the app does about that.
    public static func effective(categoryLibs: [JfItem], saved: [String]?) -> [String] {
        guard !categoryLibs.isEmpty else { return [] }
        guard let saved else { return categoryLibs.count == 1 ? [categoryLibs[0].id] : [] }
        return saved.filter { id in categoryLibs.contains { $0.id == id } }
    }

    /// What the app browses: `effective`, except that a category never chosen
    /// shows all of its libraries instead of nothing. The phone has always
    /// shown every movie and show, and a person with two movie libraries who
    /// never opened the picker should not lose one. Choosing in Settings
    /// (including choosing none) always wins.
    public static func selection(categoryLibs: [JfItem], saved: [String]?) -> [String] {
        saved == nil ? categoryLibs.map(\.id) : effective(categoryLibs: categoryLibs, saved: saved)
    }

    /// One card per series for Continue Watching, so a binged show appears
    /// once. Keeps the first episode seen per series, so the caller's order
    /// decides which wins: partway-through episodes first, then Next Up, which
    /// means a half-watched episode beats its show's Next Up entry. An episode
    /// with no series id is its own entry, never merged with another such one.
    /// Movies pass through.
    public static func onePerSeries(_ items: [JfItem]) -> [JfItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard item.type == "Episode", let series = item.seriesId, !series.isEmpty else { return true }
            return seen.insert(series).inserted
        }
    }

    /// Most recently played first, across several libraries' results joined
    /// together (the server's DatePlayed order only holds within one query).
    public static func byRecentPlay(_ items: [JfItem]) -> [JfItem] {
        items.sorted {
            ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "")
        }
    }
}

/// What a movie or show grid is sorted by. Random has no server key worth
/// paging (each page is a fresh draw), so the grids, which load whole
/// libraries, shuffle what they hold.
public enum VideoSortField: String, Sendable, CaseIterable {
    case name, year, added, random

    public var serverSortBy: String {
        switch self {
        case .name, .random: "SortName"
        case .year: "ProductionYear,SortName"
        case .added: "DateCreated,SortName"
        }
    }

    public var defaultDirection: SortDirection { self == .year || self == .added ? .descending : .ascending }
}

/// One library's worth of a video grid.
public struct VideoGroup: Sendable, Identifiable {
    public var libraryId: String
    public var items: [JfItem]
    public var id: String { libraryId }

    public init(libraryId: String, items: [JfItem]) {
        self.libraryId = libraryId
        self.items = items
    }
}

/// Which groups the user collapsed in a grouped poster grid, persisted as
/// `cascade.collapsedLibs` (a JSON array of library ids, as the desktop keeps
/// it). Anything that is not a plain array of strings reads as nothing
/// collapsed.
public enum CollapsedLibraries {
    public static func decode(_ raw: String?) -> Set<String> {
        guard let data = raw?.data(using: .utf8),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return Set(ids.compactMap { $0 as? String })
    }

    public static func encode(_ ids: Set<String>) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ids.sorted())
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

public extension JellyfinClient {
    /// The user's movie and TV libraries.
    func videoLibraries() async throws -> (movies: [JfItem], shows: [JfItem]) {
        let all = try await views()
        return (all.filter { $0.collectionType == VideoLibraries.movieType },
                all.filter { $0.collectionType == VideoLibraries.showType })
    }

    /// Movies or shows, one query per library so a grid can group them. With
    /// no library ids it is one unscoped query, returned as a single group
    /// with an empty library id.
    ///
    /// Every list is paged to the end rather than capped: a library past 500
    /// titles used to just stop.
    func videoGroups(type: String, libraryIds: [String], sortBy: String = "SortName",
                     sortOrder: String = "Ascending", filter: BrowseFilter = .init()) async throws -> [VideoGroup] {
        let parents: [String?] = libraryIds.isEmpty ? [nil] : libraryIds
        let userId = currentConfig.userId
        return try await withThrowingTaskGroup(of: (Int, VideoGroup).self) { group in
            for (index, parent) in parents.enumerated() {
                group.addTask {
                    var items: [JfItem] = []
                    var start = 0
                    while true {
                        let params: [String: String?] = [
                            "userId": userId, "includeItemTypes": type,
                            "recursive": "true", "parentId": parent, "sortBy": sortBy, "sortOrder": sortOrder,
                            "fields": "ProductionYear,Genres", "limit": "300", "startIndex": String(start),
                        ]
                        let page: JfItemsResponse = try await self.get("/Items", params: params.applying(filter))
                        let got = page.items ?? []
                        items += got
                        // A short page is the end; asking again past it would
                        // only return nothing.
                        if got.count < 300 { break }
                        start += 300
                    }
                    return (index, VideoGroup(libraryId: parent ?? "", items: items))
                }
            }
            var out: [(Int, VideoGroup)] = []
            for try await part in group { out.append(part) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Home's Continue Watching: what is partway through, then the next
    /// episode of each show being followed, one card per show, at most 24.
    /// Next Up is best effort: its failure still leaves the resume list.
    func continueWatchingMerged(movieIds: [String], showIds: [String], limit: Int = 24) async throws -> [JfItem] {
        let fields = "UserData,ProductionYear,SeriesPrimaryImageTag"
        let userId = currentConfig.userId
        let all = movieIds + showIds
        var partway: [JfItem] = []
        try await withThrowingTaskGroup(of: [JfItem].self) { group in
            for parent in all.isEmpty ? [nil] : all.map(Optional.some) {
                group.addTask {
                    let params: [String: String?] = [
                        "userId": userId, "includeItemTypes": "Movie,Episode",
                        "filters": "IsResumable", "recursive": "true", "parentId": parent,
                        "sortBy": "DatePlayed", "sortOrder": "Descending", "fields": fields, "limit": String(limit),
                    ]
                    let r: JfItemsResponse = try await self.get("/Items", params: params)
                    return r.items ?? []
                }
            }
            for try await part in group { partway += part }
        }
        var next: [JfItem] = []
        for parent in showIds.isEmpty ? [nil] : showIds.map(Optional.some) {
            let params: [String: String?] = [
                "userId": userId, "parentId": parent, "fields": fields,
                "limit": String(limit), "enableResumable": "false",
            ]
            let r: JfItemsResponse? = try? await get("/Shows/NextUp", params: params)
            next += r?.items ?? []
        }
        return Array(VideoLibraries.onePerSeries(VideoLibraries.byRecentPlay(partway) + next).prefix(limit))
    }

    /// Recently added movies or episodes, from the chosen libraries only,
    /// newest first. /Items/Latest takes one parent, so each library is asked
    /// and the results merged.
    func latestVideo(_ type: String, libraryIds: [String], limit: Int = 20) async throws -> [JfItem] {
        var found: [JfItem] = []
        for parent in libraryIds.isEmpty ? [nil] : libraryIds.map(Optional.some) {
            let params: [String: String?] = [
                "userId": currentConfig.userId, "includeItemTypes": type, "parentId": parent,
                "limit": String(limit), "groupItems": "false",
                "fields": "ProductionYear,DateCreated,SeriesPrimaryImageTag",
            ]
            let items: [JfItem] = try await get("/Items/Latest", params: params)
            found += items
        }
        return Array(found.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }.prefix(limit))
    }

    /// Genre names present on items of these types in the given libraries,
    /// for the filter menu. Names, not ids: the desktop stores the genre's
    /// name in its prefs, and the items route filters by it.
    func genreNames(types: String, libraryIds: [String] = []) async throws -> [String] {
        var names = Set<String>()
        for parent in libraryIds.isEmpty ? [nil] : libraryIds.map(Optional.some) {
            let params: [String: String?] = [
                "userId": currentConfig.userId, "includeItemTypes": types, "parentId": parent,
                "sortBy": "SortName",
            ]
            let r: JfItemsResponse = try await get("/Genres", params: params)
            names.formUnion((r.items ?? []).compactMap(\.name))
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Years with items of this type in the given libraries, for the decade filter.
    func years(of itemType: String, libraryIds: [String]) async throws -> [Int] {
        struct Filters: Decodable { var years: [Int]? }
        var years = Set<Int>()
        for parent in libraryIds.isEmpty ? [nil] : libraryIds.map(Optional.some) {
            let params: [String: String?] = [
                "userId": currentConfig.userId, "parentId": parent,
                "includeItemTypes": itemType, "recursive": "true",
            ]
            let found: Filters = try await get("/Items/Filters", params: params)
            years.formUnion(found.years ?? [])
        }
        return years.sorted()
    }

    /// Movies or shows matching a search term, in the given libraries.
    func searchVideo(_ term: String, type: String, libraryIds: [String], limit: Int = 8) async throws -> [JfItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var found: [JfItem] = []
        for parent in libraryIds.isEmpty ? [nil] : libraryIds.map(Optional.some) {
            let params: [String: String?] = [
                "userId": currentConfig.userId, "searchTerm": trimmed, "includeItemTypes": type,
                "recursive": "true", "parentId": parent, "fields": "ProductionYear",
                "limit": String(limit),
            ]
            let r: JfItemsResponse = try await get("/Items", params: params)
            found += r.items ?? []
        }
        return Array(found.prefix(limit))
    }
}
