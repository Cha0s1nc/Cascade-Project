import Foundation
import UniformTypeIdentifiers

// What is downloaded, as one value: the single source of truth for offline
// playback and, since version 2, for Offline Mode's library (Finamp's lesson:
// one index, not several stores kept in step by hand). Pure, so the rules that
// decide what a removal may delete are tested here; OfflineLibrary owns the
// files and the one copy on disk, and OfflineQuery answers the screens'
// requests from it.
//
// Paths are relative to the offline folder: the app container's absolute
// path changes on every install.
//
// Version 2 (docs/offline-mode-plan.md, section 1) keeps version 1's shape
// and adds to it, the desktop's src/core/offline-index.ts likewise: video,
// the library each item came from, the user, lyrics, subtitles, media
// segments and the history snapshot. A version 1 file has none of these keys;
// init(from:) reads every one as optional, because a synthesized decoder
// would throw on the first missing key and decode() would then answer an
// empty index, which is every download gone.

public struct OfflineIndex: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public struct Track: Codable, Sendable, Equatable {
        /// The single-item fetch, so it carries the loudness gain the list
        /// queries leave out and normalization works with no server.
        public var item: JfItem
        /// "media/<id>.<ext>" once the whole file is on disk; nil until then.
        public var file: String?
        public var bytes: Int = 0
        /// The library it was downloaded from. Nil for items from a version 1
        /// index, or until the library is looked up: library(of:) then answers
        /// the placeholder for its kind.
        public var library: String?
        public var lyrics: StoredLyrics?
        public var subs: [Subtitle]?
        public var segments: [Segment]?
        /// The Cascade plugin's explicit flag, so the badge shows offline.
        public var explicit: Bool?
        /// When the file landed: an episode finished before it was downloaded
        /// is not "watched" for removal.
        public var readyAt: Date?
        /// When this device played it to the end.
        public var watchedAt: Date?
        /// Video: what the server did to make the file (OfflineVideo).
        public var outcome: DownloadOutcome?
        /// Video: a picture subtitle's stream index to burn in, asked for at
        /// download time; the only way such subtitles show offline.
        public var burnIn: Int?

        public init(item: JfItem, file: String? = nil, bytes: Int = 0) {
            self.item = item
            self.file = file
            self.bytes = bytes
        }
    }

    /// What the person asked for: an album, a playlist, a movie, a season or
    /// a whole series. A track shared by two of them is stored once.
    public struct Collection: Codable, Sendable, Equatable, Identifiable {
        public var item: JfItem
        public var trackIds: [String]
        /// A series only: "Download new episodes as they arrive" is on, since
        /// then. Episodes added to the server after it are fetched.
        public var follow: Date? = nil
        /// A series only: episodes removed as watched, never fetched again by
        /// the follow (the server may not know yet that they were watched).
        public var skip: [String]? = nil
        public var id: String { item.id }
    }

    /// A play the server never heard about (its start report failed), to be
    /// sent as /UserPlayedItems?datePlayed. Jellyfin counts a play when
    /// playback STARTS (SessionManager.OnPlaybackStart), so that report is
    /// the one whose loss loses a play.
    public struct Play: Codable, Sendable, Equatable {
        public var itemId: String
        public var userId: String
        public var date: Date
    }

    /// A library as /UserViews names it.
    public struct LibraryView: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var collectionType: String
    }

    /// The Policy fields the apps read.
    public struct Policy: Codable, Sendable, Equatable {
        public var isAdministrator: Bool?
        public var enableContentDeletion: Bool?
        public var enableContentDeletionFromFolders: [String]?
        public var enableContentDownloading: Bool?
        public var enableLiveTvAccess: Bool?

        public init(isAdministrator: Bool? = nil, enableContentDeletion: Bool? = nil,
                    enableContentDeletionFromFolders: [String]? = nil, enableContentDownloading: Bool? = nil,
                    enableLiveTvAccess: Bool? = nil) {
            self.isAdministrator = isAdministrator
            self.enableContentDeletion = enableContentDeletion
            self.enableContentDeletionFromFolders = enableContentDeletionFromFolders
            self.enableContentDownloading = enableContentDownloading
            self.enableLiveTvAccess = enableLiveTvAccess
        }
    }

    public struct User: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var policy: Policy

        public init(id: String, name: String, policy: Policy) {
            self.id = id
            self.name = name
            self.policy = policy
        }
    }

    /// One row of the server's play history as it stood.
    public struct HistoryEntry: Codable, Sendable, Equatable {
        public var id: String
        public var lastPlayedDate: String?
        public var playCount: Int
    }

    /// The server's play history when the app was last online, newest
    /// first: what reconnecting compares against before replaying offline
    /// plays (plan, section 5).
    public struct History: Codable, Sendable, Equatable {
        public var takenAt: Date
        public var entries: [HistoryEntry]
    }

    /// Lyrics saved with a track, already parsed: the waterfall's answer at
    /// download time.
    public struct StoredLyrics: Codable, Sendable, Equatable {
        /// "cascade", "spicy", "kugou", "lrclib", "jellyfin".
        public var source: String
        public var synced: Bool
        public var lines: [LyricLine]
        public var savedAt: Date
        /// SpicyLyrics are kept no longer than the plugin's own cache may
        /// keep them (spicyLyricsDays); every other source never expires.
        public var expiresAt: Date?
        /// SpicyLyrics' credit, which must show wherever they do.
        public var credit: SpicyCredit?

        public init(source: String, synced: Bool, lines: [LyricLine], savedAt: Date, expiresAt: Date?,
                    credit: SpicyCredit? = nil) {
            self.source = source
            self.synced = synced
            self.lines = lines
            self.savedAt = savedAt
            self.expiresAt = expiresAt
            self.credit = credit
        }

        enum CodingKeys: String, CodingKey { case source, synced, lines, savedAt, expiresAt, credit }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = try c.decode(String.self, forKey: .source)
            synced = (try? c.decodeIfPresent(Bool.self, forKey: .synced)) ?? false
            lines = try c.decode([LyricLine].self, forKey: .lines)
            savedAt = try c.decode(Date.self, forKey: .savedAt)
            expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
            // A credit that does not read leaves the lyrics, not the track, out.
            credit = (try? c.decodeIfPresent(SpicyCredit.self, forKey: .credit)) ?? nil
        }

        /// The key a source is stored under, from the label the lyrics
        /// search reports (LyricSources). SpicyLyrics are told apart by their
        /// credit, since their label is the provider's name. The same rule as
        /// the desktop's lyricsSourceKey.
        public static func sourceKey(label: String, hasCredit: Bool) -> String {
            if hasCredit { return "spicy" }
            let l = label.lowercased()
            if l.hasPrefix("kugou") { return "kugou" }
            if l.hasPrefix("lrclib") { return "lrclib" }
            if l.hasPrefix("jellyfin") { return "jellyfin" }
            return "cascade"
        }

        /// How the lyrics UI names where these came from.
        public var sourceLabel: String {
            if let credit { return credit.provider }
            return ["cascade": "Cascade", "kugou": "Kugou", "lrclib": "LRCLIB", "jellyfin": "Jellyfin"][source] ?? source
        }
    }

    /// An external text subtitle saved beside a video, as WebVTT.
    public struct Subtitle: Codable, Sendable, Equatable {
        /// The stream's index in the item's MediaStreams.
        public var index: Int
        /// "subs/<id>.<index>.vtt".
        public var file: String
        public var language: String?
        public var title: String?
        public var isDefault: Bool?
        public var isForced: Bool?

        public init(index: Int, file: String, language: String? = nil, title: String? = nil,
                    isDefault: Bool? = nil, isForced: Bool? = nil) {
            self.index = index
            self.file = file
            self.language = language
            self.title = title
            self.isDefault = isDefault
            self.isForced = isForced
        }
    }

    /// One /MediaSegments entry (intro, credits), as the server sent it.
    public struct Segment: Codable, Sendable, Equatable {
        public var type: String
        public var startTicks: Int
        public var endTicks: Int

        public init(type: String, startTicks: Int, endTicks: Int) {
            self.type = type
            self.startTicks = startTicks
            self.endTicks = endTicks
        }
    }

    public var version: Int = currentVersion
    /// Every file-backed item: a track, a movie or an episode. Still called
    /// tracks, as in version 1, which OfflineLibrary and the screens read.
    public var tracks: [String: Track] = [:]
    /// Newest first.
    public var collections: [Collection] = []
    public var plays: [Play] = []
    /// Album loudness gains (dB) for the albums downloaded tracks belong to,
    /// so album-mode normalization works offline, and for a playlist's
    /// tracks too. Only albums that have one.
    public var albumGains: [String: Double] = [:]
    /// Series and seasons the downloaded episodes belong to, by id.
    public var containers: [String: JfItem] = [:]
    /// The libraries downloaded items came from.
    public var libraries: [LibraryView] = []
    public var user: User?
    public var history: History?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, tracks, collections, plays, albumGains, containers, libraries, user, history
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = Self.currentVersion
        tracks = try c.decodeIfPresent([String: Track].self, forKey: .tracks) ?? [:]
        collections = try c.decodeIfPresent([Collection].self, forKey: .collections) ?? []
        plays = try c.decodeIfPresent([Play].self, forKey: .plays) ?? []
        albumGains = try c.decodeIfPresent([String: Double].self, forKey: .albumGains) ?? [:]
        containers = (try? c.decodeIfPresent([String: JfItem].self, forKey: .containers)) ?? [:]
        libraries = (try? c.decodeIfPresent([LibraryView].self, forKey: .libraries)) ?? []
        user = try? c.decodeIfPresent(User.self, forKey: .user)
        history = try? c.decodeIfPresent(History.self, forKey: .history)
    }

    /// How long SpicyLyrics may be kept: the plugin's own cache rule.
    public static let spicyLyricsDays = 25
    /// Rows of play history kept in the snapshot.
    public static let maxHistoryEntries = 200

    /// The item types that are files of their own.
    static let mediaTypes: Set<String> = ["Audio", "Movie", "Episode"]
    /// The item types a collection may be.
    static let collectionTypes: Set<String> = ["MusicAlbum", "Playlist", "Movie", "Episode", "Season", "Series"]

    // MARK: - Libraries

    /// Where items with no known library go: everything from a version 1
    /// index, and anything downloaded before its library was looked up. One
    /// per kind, so Music and Video still split the way the mode switch
    /// expects. The same ids as the desktop's PLACEHOLDER_LIBRARIES.
    public static let placeholderLibraries: [String: LibraryView] = [
        "Audio": LibraryView(id: "cascade-offline-music", name: "Downloads", collectionType: "music"),
        "Movie": LibraryView(id: "cascade-offline-movies", name: "Downloaded Movies", collectionType: "movies"),
        "Episode": LibraryView(id: "cascade-offline-shows", name: "Downloaded Shows", collectionType: "tvshows"),
    ]
    /// In the order /UserViews lists them.
    public static let placeholderOrder = ["Audio", "Movie", "Episode"]

    public static func isPlaceholderLibrary(_ id: String) -> Bool {
        placeholderLibraries.values.contains { $0.id == id }
    }

    /// A library id: a GUID with or without dashes, or a placeholder's.
    public static func isSafeLibraryId(_ id: String) -> Bool { isSafeUserId(id) }

    static func placeholder(for item: JfItem) -> LibraryView {
        placeholderLibraries[item.type == "Movie" || item.type == "Episode" ? item.type! : "Audio"]!
    }

    /// The library a downloaded item belongs to: the one it was downloaded
    /// from when that is known and still listed, otherwise its placeholder.
    public func library(of trackId: String) -> String? {
        guard let t = tracks[trackId] else { return nil }
        if let lib = t.library, libraries.contains(where: { $0.id == lib }) { return lib }
        return Self.placeholder(for: t.item).id
    }

    /// Items still in a placeholder library, for the online lookup to place.
    public var unplacedTrackIds: [String] {
        tracks.keys.filter { Self.isPlaceholderLibrary(library(of: $0) ?? "") }.sorted()
    }

    /// The libraries Offline Mode lists (/UserViews): every stored library
    /// that holds a downloaded item, then each placeholder that holds one.
    public var librariesInUse: [LibraryView] {
        let used = Set(tracks.keys.compactMap { library(of: $0) })
        return libraries.filter { used.contains($0.id) }
            + Self.placeholderOrder.compactMap { Self.placeholderLibraries[$0] }.filter { used.contains($0.id) }
    }

    /// Stores the server's library list (/UserViews), keeping the kinds that
    /// can hold downloads.
    public mutating func setLibraries(_ views: [JfItem]) {
        let kinds: Set<String> = ["music", "musicvideos", "movies", "tvshows"]
        var seen = Set<String>()
        libraries = views.compactMap { v in
            guard Self.isSafeLibraryId(v.id), !Self.isPlaceholderLibrary(v.id), !seen.contains(v.id),
                  let kind = v.collectionType, kinds.contains(kind) else { return nil }
            seen.insert(v.id)
            return LibraryView(id: v.id, name: v.name ?? "", collectionType: kind)
        }
    }

    /// Places items in a library the lookup found them in. A library not in
    /// the stored list is refused, so a stray id cannot hide an item.
    public mutating func assignLibrary(_ trackIds: [String], to libraryId: String) {
        guard libraries.contains(where: { $0.id == libraryId }) else { return }
        for id in trackIds where tracks[id] != nil { tracks[id]?.library = libraryId }
    }

    /// Fills in, from a fresh server answer, the fields version 1 never kept
    /// (the desktop's refreshItems). Anything the answer leaves out is kept.
    public mutating func refresh(_ items: [JfItem]) {
        for fresh in items {
            guard var item = tracks[fresh.id]?.item else { continue }
            item.artistItems = fresh.artistItems ?? item.artistItems
            item.albumArtists = fresh.albumArtists ?? item.albumArtists
            item.genreItems = fresh.genreItems ?? item.genreItems
            item.genres = fresh.genres ?? item.genres
            item.userData = fresh.userData ?? item.userData
            item.dateCreated = fresh.dateCreated ?? item.dateCreated
            item.sortName = fresh.sortName ?? item.sortName
            item.productionYear = fresh.productionYear ?? item.productionYear
            item.overview = fresh.overview ?? item.overview
            tracks[fresh.id]?.item = item
        }
    }

    // MARK: - Reading

    public func collection(_ id: String) -> Collection? { collections.first { $0.id == id } }

    /// Downloaded, as opposed to asked for.
    public func readyFile(_ trackId: String) -> String? { tracks[trackId]?.file }

    /// Tracks still to fetch, in the order they were asked for.
    public var pending: [String] {
        var seen = Set<String>()
        return collections.reversed().flatMap(\.trackIds).filter {
            tracks[$0]?.file == nil && seen.insert($0).inserted
        }
    }

    public func progress(_ collectionId: String) -> (done: Int, total: Int) {
        let ids = collection(collectionId)?.trackIds ?? []
        return (ids.filter { tracks[$0]?.file != nil }.count, ids.count)
    }

    public var totalBytes: Int { tracks.values.reduce(0) { $0 + $1.bytes } }

    /// Every file the index points at: ready media and saved subtitles.
    public var files: Set<String> {
        Set(tracks.values.flatMap { t in (t.file.map { [$0] } ?? []) + (t.subs ?? []).map(\.file) })
    }

    /// Lyrics saved with a track, or nil when there are none or they have
    /// expired (SpicyLyrics past spicyLyricsDays: shown no longer).
    public func lyrics(of trackId: String, now: Date) -> StoredLyrics? {
        guard let l = tracks[trackId]?.lyrics else { return nil }
        if let expires = l.expiresAt, expires <= now { return nil }
        return l
    }

    /// Tracks whose saved lyrics have expired: to be refetched while online,
    /// or dropped when that fails.
    public func expiredLyricsTrackIds(now: Date) -> [String] {
        tracks.keys.filter { tracks[$0]?.lyrics != nil && lyrics(of: $0, now: now) == nil }.sorted()
    }

    // MARK: - Changing

    /// The item as the catalog keeps it: an audio file needs no stream list,
    /// and only the first media source is ever read.
    static func slimmed(_ item: JfItem) -> JfItem {
        var item = item
        if let first = item.mediaSources?.first { item.mediaSources = [first] }
        if item.type != "Movie" && item.type != "Episode" {
            item.mediaStreams = nil
            item.chapters = nil
        }
        item.sourceLibrary = nil
        return item
    }

    /// Asks for a collection: an album or playlist with its tracks, a movie
    /// with itself, a season or series with its episodes. Asking again
    /// refreshes its list; items already on disk are kept, not fetched twice.
    /// `containers` are the series and seasons the episodes belong to. Items
    /// that are not audio, a movie or an episode are dropped, and so is an id
    /// that cannot be a file name.
    public mutating func add(_ collection: JfItem, tracks list: [JfItem], containers parents: [JfItem] = []) {
        let media = list.filter { Self.isSafeId($0.id) && ($0.type == nil || Self.mediaTypes.contains($0.type!)) }
        collections.removeAll { $0.id == collection.id }
        collections.insert(Collection(item: Self.slimmed(collection), trackIds: media.map(\.id)), at: 0)
        for track in media {
            if var existing = tracks[track.id] {
                existing.item = Self.slimmed(track)
                tracks[track.id] = existing
            } else {
                tracks[track.id] = Track(item: Self.slimmed(track))
            }
        }
        for parent in parents where Self.isSafeId(parent.id) && (parent.type == "Series" || parent.type == "Season") {
            containers[parent.id] = Self.slimmed(parent)
        }
    }

    public mutating func markReady(_ trackId: String, file: String, bytes: Int, now: Date? = nil) {
        tracks[trackId]?.file = file
        tracks[trackId]?.bytes = bytes
        if let now, tracks[trackId] != nil { tracks[trackId]?.readyAt = now }
    }

    /// Containers nothing downloaded still belongs to.
    private mutating func pruneContainers() {
        let held = Set(tracks.values.flatMap { [$0.item.seriesId, $0.item.seasonId].compactMap { $0 } })
        containers = containers.filter { held.contains($0.key) }
    }

    /// Drops a collection, and with it every item no other collection still
    /// holds, and the series and seasons nothing left belongs to. Returns the
    /// files that are now nobody's, to delete (media and subtitles).
    @discardableResult
    public mutating func remove(_ collectionId: String) -> [String] {
        collections.removeAll { $0.id == collectionId }
        let kept = Set(collections.flatMap(\.trackIds))
        var orphaned: [String] = []
        for (id, track) in tracks where !kept.contains(id) {
            if let file = track.file { orphaned.append(file) }
            orphaned += (track.subs ?? []).map(\.file)
            tracks[id] = nil
        }
        let albums = Set(tracks.values.compactMap(\.item.albumId))
        albumGains = albumGains.filter { albums.contains($0.key) }
        pruneContainers()
        return orphaned.sorted()
    }

    /// Brings the index in line with the disk after a crash, a relaunch or a
    /// user poking at the container: a ready track whose file is gone goes
    /// back to pending, a subtitle whose file is gone is forgotten. Returns
    /// files on disk the index does not know, to delete (a download finished
    /// after its collection was removed).
    public mutating func reconcile(filesOnDisk: Set<String>) -> [String] {
        for (id, track) in tracks {
            if let file = track.file, !filesOnDisk.contains(file) {
                tracks[id]?.file = nil
                tracks[id]?.bytes = 0
            }
            if let subs = track.subs {
                let kept = subs.filter { filesOnDisk.contains($0.file) }
                tracks[id]?.subs = kept.isEmpty ? nil : kept
            }
        }
        return filesOnDisk.subtracting(files).sorted()
    }

    /// Saves a track's lyrics. SpicyLyrics get an expiry spicyLyricsDays out.
    public mutating func setLyrics(_ trackId: String, source: String, synced: Bool, lines: [LyricLine], now: Date,
                                   credit: SpicyCredit? = nil) {
        guard tracks[trackId] != nil, !source.isEmpty, !lines.isEmpty else { return }
        let expires = source == "spicy" ? now.addingTimeInterval(Double(Self.spicyLyricsDays) * 86_400) : nil
        tracks[trackId]?.lyrics = StoredLyrics(source: source, synced: synced, lines: lines, savedAt: now, expiresAt: expires,
                                               credit: credit.flatMap { $0.provider.isEmpty ? nil : $0 })
    }

    public mutating func dropLyrics(_ trackId: String) { tracks[trackId]?.lyrics = nil }

    public mutating func setSubtitles(_ trackId: String, _ subs: [Subtitle]) {
        guard tracks[trackId] != nil else { return }
        let valid = Self.validSubtitles(subs)
        tracks[trackId]?.subs = valid.isEmpty ? nil : valid
    }

    public mutating func setSegments(_ trackId: String, _ segments: [Segment]) {
        guard tracks[trackId] != nil else { return }
        let valid = segments.filter { $0.endTicks > $0.startTicks }
        tracks[trackId]?.segments = valid.isEmpty ? nil : valid
    }

    public mutating func setExplicit(_ trackId: String, _ explicit: Bool) {
        guard tracks[trackId] != nil else { return }
        tracks[trackId]?.explicit = explicit ? true : nil
    }

    /// Stores the signed-in user, refusing one whose id could not name a
    /// folder (the same rule as the account's offline folder).
    public mutating func setUser(_ user: User?) {
        self.user = user.flatMap { Self.isSafeUserId($0.id) ? $0 : nil }
    }

    /// The rows a snapshot keeps, from the server's played items, newest
    /// first.
    public static func historyEntries(of items: [JfItem]) -> [HistoryEntry] {
        items.filter { isSafeId($0.id) }.prefix(maxHistoryEntries).map {
            HistoryEntry(id: $0.id, lastPlayedDate: $0.userData?.lastPlayedDate, playCount: $0.userData?.playCount ?? 0)
        }
    }

    public mutating func setHistory(_ items: [JfItem], takenAt: Date) {
        history = History(takenAt: takenAt, entries: Self.historyEntries(of: items))
    }

    // MARK: - Storage

    /// A stored index, validated: it is read from disk, where anything can
    /// be. A path that could leave the offline folder is dropped, and an
    /// unreadable file is an empty index rather than a crash. A version 1
    /// file reads as is.
    public static func decode(_ data: Data?) -> OfflineIndex {
        guard let data, let index = try? JSONDecoder().decode(OfflineIndex.self, from: data) else { return OfflineIndex() }
        return index.validated()
    }

    /// The same checks decode() makes, for an index decoded some other way
    /// (the shared test fixture, which is in the desktop's key case).
    public func validated() -> OfflineIndex {
        var index = self
        index.version = Self.currentVersion
        for (id, track) in index.tracks {
            if track.file.map(Self.isSafeMediaPath) == false {
                index.tracks[id]?.file = nil
                index.tracks[id]?.bytes = 0
            }
            if let lib = track.library, !Self.isSafeLibraryId(lib) || Self.isPlaceholderLibrary(lib) {
                index.tracks[id]?.library = nil
            }
            if let subs = track.subs {
                let valid = Self.validSubtitles(subs)
                index.tracks[id]?.subs = valid.isEmpty ? nil : valid
            }
            if let segments = track.segments {
                let valid = segments.filter { $0.endTicks > $0.startTicks }
                index.tracks[id]?.segments = valid.isEmpty ? nil : valid
            }
            if let burn = track.burnIn, burn < 0 { index.tracks[id]?.burnIn = nil }
            if track.file == nil { index.tracks[id]?.readyAt = nil }
            // SpicyLyrics with no expiry are treated as expired rather than
            // kept for good.
            if let l = track.lyrics, l.source == "spicy", l.expiresAt == nil {
                index.tracks[id]?.lyrics?.expiresAt = l.savedAt
            }
        }
        let known = Set(index.tracks.keys)
        for i in index.collections.indices {
            index.collections[i].trackIds.removeAll { !known.contains($0) }
            if index.collections[i].item.type != "Series" { index.collections[i].follow = nil }
            if index.collections[i].follow == nil { index.collections[i].skip = nil }
            index.collections[i].skip = index.collections[i].skip.map { Array($0.filter(Self.isSafeId).suffix(Self.maxSkippedEpisodes)) }
        }
        index.collections.removeAll { $0.item.type.map { !Self.collectionTypes.contains($0) } ?? false }
        index.containers = index.containers.filter { Self.isSafeId($0.key) && $0.value.id == $0.key
            && ($0.value.type == "Series" || $0.value.type == "Season") }
        index.setLibraries(index.libraries.map { JfItem(id: $0.id, name: $0.name, collectionType: $0.collectionType) })
        if let user = index.user, !Self.isSafeUserId(user.id) { index.user = nil }
        if let h = index.history {
            index.history?.entries = Array(h.entries.filter { Self.isSafeId($0.id) }.prefix(Self.maxHistoryEntries))
        }
        index.pruneContainers()
        return index
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// An id fit to become a file name: Jellyfin's are hex, and one from
    /// anywhere else must not become a path.
    public static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// A Jellyfin user id (a GUID, with or without dashes). It names the
    /// account's folder, so it must never be a path.
    public static func isSafeUserId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.contains(where: { $0 != "-" })
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A background download's name: the account and the track. The session
    /// outlives a sign-out, so a transfer that finishes after one says whose
    /// folder it belongs to.
    /// A transcode adds its item's runtime, which the finished file is
    /// checked against (it has no length to check).
    public static func taskName(owner: String, itemId: String, transcodeRunTicks: Int? = nil) -> String {
        "\(owner)/\(itemId)" + (transcodeRunTicks.map { "/\($0)" } ?? "")
    }

    public static func parseTaskName(_ name: String?) -> (owner: String, itemId: String)? {
        let parts = (name ?? "").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || (parts.count == 3 && Int(parts[2]) != nil),
              isSafeUserId(parts[0]), isSafeId(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// The runtime a transcode's task name carries, or nil for any other.
    public static func transcodeRunTicks(_ name: String?) -> Int? {
        guard parseTaskName(name) != nil else { return nil }
        let parts = (name ?? "").split(separator: "/")
        return parts.count == 3 ? Int(parts[2]) : nil
    }

    /// Whether a queued play the server refused should be dropped rather
    /// than retried. The item is gone (deleted or re-scanned since) or the
    /// request can never succeed (another server), so retrying would jam
    /// every play queued behind it. Anything else (no response, 401, 5xx)
    /// may clear up, so the play is kept.
    public static func dropsPlay(afterStatus status: Int) -> Bool {
        status == 400 || status == 404
    }

    /// "media/" plus a plain file name: no separators, no "..".
    static func isSafeMediaPath(_ path: String) -> Bool {
        guard path.hasPrefix("media/") else { return false }
        let name = path.dropFirst("media/".count)
        return !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            && !name.hasPrefix(".")
    }

    /// "subs/<id>.<index>.vtt".
    static func isSafeSubtitlePath(_ path: String) -> Bool {
        guard path.hasPrefix("subs/"), path.hasSuffix(".vtt") else { return false }
        let parts = path.dropFirst("subs/".count).dropLast(".vtt".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, isSafeId(String(parts[0])) else { return false }
        return (1...4).contains(parts[1].count) && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func validSubtitles(_ subs: [Subtitle]) -> [Subtitle] {
        var seen = Set<Int>()
        return subs.filter { $0.index >= 0 && isSafeSubtitlePath($0.file) && seen.insert($0.index).inserted }
    }

    /// The extension a downloaded file is saved under. AVFoundation picks
    /// the parser for a local file by its extension, so a wrong or missing
    /// one is a file that will not play. The server's file name first
    /// (/Download sends the original's), then the MIME type. Either has to
    /// name audio: an error page a proxy answered 200 with is not a track,
    /// whatever its file name says.
    public static func fileExtension(suggestedFilename: String?, mimeType: String?) -> String? {
        if let name = suggestedFilename, let dot = name.lastIndex(of: ".") {
            let ext = name[name.index(after: dot)...].lowercased()
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }),
               UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) == true { return ext }
        }
        guard let mimeType, let type = UTType(mimeType: mimeType),
              type.conforms(to: .audiovisualContent) else { return nil }
        return type.preferredFilenameExtension
    }
}

extension JfItem {
    /// A library view as the catalog rebuilds one.
    init(id: String, name: String, collectionType: String) {
        self.init(id: id, name: name)
        self.collectionType = collectionType
    }
}
