import Foundation
import Observation

/// Downloaded albums and playlists: the files, their covers, and the index
/// that says what is where. One per app launch, never per sign-in: it owns
/// the background download session, and a second session with the same
/// identifier misbehaves.
///
/// Files come from /Items/{id}/Download, the original file, which honors the
/// admin's "Allow media downloading" switch. /Items/{id}/File would hand the
/// original to anyone signed in and quietly sidestep it.
///
/// One folder per account, `base/<userId>` (Application Support, excluded
/// from backup; Caches would be purged under storage pressure), so whoever
/// signs in next never sees, plays or resumes the last account's downloads.
/// Jellyfin user ids are GUIDs, unique across servers. Inside each:
///   index.json          OfflineIndex
///   media/<id>.<ext>    one file per track, movie or episode, shared between collections
///   subs/<id>.<n>.vtt   a video's text subtitle stream n, as WebVTT
///   art/<id>.jpg        600 px covers, posters and episode stills
/// ponytail: a user deleted on the server leaves its folder behind.
@MainActor
@Observable
public final class OfflineLibrary {
    public private(set) var index: OfflineIndex
    /// Tracks with a transfer in flight, for progress on the Downloads screen.
    public private(set) var active: Set<String> = []
    public private(set) var lastError: String?
    /// Items with a cover on disk.
    private var art: Set<String>

    /// The signed-in account (AppState sets it), and its folder. Nil with
    /// nobody signed in: then nothing is listed, played from disk or fetched.
    public private(set) var owner: String?
    public private(set) var root: URL?
    @ObservationIgnored private let base: URL
    @ObservationIgnored private let delegate: DownloadDelegate
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var replaying = false
    /// Called after every change to the index is saved: AppState hands the
    /// new catalog to the client while Offline Mode is on.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    /// Offline Mode is on: no transfer is started, and the running ones were
    /// cancelled (they start again from resume() once back online).
    public private(set) var paused = false

    /// One transfer as the Downloads screen shows it.
    public struct Transfer: Sendable, Equatable {
        public var received: Int64 = 0
        /// The length the server sent, nil for a transcode (it sends none).
        public var expected: Int64?
        /// Video only: what the server is doing, and roughly how big it gets.
        public var outcome: DownloadOutcome?
        public var estimate: Int?
        public var startedAt = Date()

        /// "Converting on the server · about 12 minutes left".
        public var status: String? {
            guard let outcome else { return nil }
            let secs = Date().timeIntervalSince(startedAt)
            let size = expected.map(Int.init) ?? estimate
            guard secs > 3, let left = OfflineVideo.secondsLeft(received: Int(received), estimate: size,
                                                                  bytesPerSecond: Double(received) / secs) else { return outcome.label }
            let mins = Int((Double(left) / 60).rounded())
            return "\(outcome.label) · about \(mins <= 1 ? "a minute" : "\(mins) minutes") left"
        }

        public var fraction: Double? {
            guard let size = expected.map(Double.init) ?? estimate.map(Double.init), size > 0 else { return nil }
            return min(1, Double(received) / size)
        }
    }
    /// Transfers by item id, updated a few times a second.
    public private(set) var transfers: [String: Transfer] = [:]
    /// The quality videos are asked for at (AppState keeps it set from the setting).
    @ObservationIgnored public var videoQuality: VideoQuality = .platformDefault
    /// The client the last resume ran with: a finished video starts the next
    /// one, and a cancelled transcode stops the server's encode with it.
    @ObservationIgnored private var lastClient: JellyfinClient?
    /// A running transcode's session, to stop its encode when cancelled.
    @ObservationIgnored private var playSessions: [String: String] = [:]

    /// Handed over by the app delegate when iOS relaunches the app to finish
    /// downloads in the background; called once the session has delivered
    /// everything, so iOS can suspend the app again. Static: the delegate
    /// hears about it without a way to reach this object.
    private static var backgroundCompletion: (() -> Void)?
    /// The session can finish delivering before the app delegate hands the
    /// handler over (it exists from launch), so that order is remembered.
    private static var deliveredWithoutHandler = false

    public static func handBackgroundCompletion(_ handler: @escaping () -> Void) {
        if deliveredWithoutHandler {
            deliveredWithoutHandler = false
            handler()
        } else {
            backgroundCompletion = handler
        }
    }

    public static let sessionIdentifier = "cascade.downloads"

    public static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Application Support is shared by every app on the Mac, unlike an
        // iOS app's own container, so the files go under the bundle id. It is
        // read at run time: a debug build's `.dev` id keeps its downloads out
        // of the release app's folder. iOS keeps its old path, which would
        // otherwise orphan what is already downloaded.
        return support.appending(path: Bundle.main.bundleIdentifier ?? "xyz.chaosinc.cascade", directoryHint: .isDirectory)
            .appending(path: "offline", directoryHint: .isDirectory)
        #else
        return support.appending(path: "offline", directoryHint: .isDirectory)
        #endif
    }

    public init(base: URL = OfflineLibrary.defaultRoot) {
        self.base = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var baseURL = base
        try? baseURL.setResourceValues(values)
        index = OfflineIndex()
        art = []
        delegate = DownloadDelegate(base: base)

        // Set before the session exists, so no callback can arrive without it.
        delegate.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Switches to `userId`'s downloads, or to none. Transfers for anyone else
    /// are cancelled (they resume when that account signs in again); the
    /// current account's carry on, so a relaunch does not restart them.
    public func setOwner(_ userId: String?) {
        let next = userId.flatMap { OfflineIndex.isSafeUserId($0) ? $0 : nil }
        guard next != owner || (next != nil && root == nil) else { return }
        owner = next
        index = OfflineIndex()
        art = []
        active = []
        lastError = nil
        root = next.map { base.appending(path: $0, directoryHint: .isDirectory) }
        if let root { load(root) }
        Task { [weak self] in
            guard let self else { return }
            for task in await self.session.allTasks where OfflineIndex.parseTaskName(task.taskDescription)?.owner != next {
                task.cancel()
            }
            await self.refreshActive()
        }
    }

    private func load(_ root: URL) {
        let fm = FileManager.default
        adoptFlatLayout(into: root)
        for dir in ["media", "art", "subs"] {
            try? fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        index = OfflineIndex.decode(try? Data(contentsOf: root.appending(path: "index.json")))
        art = Set(((try? fm.contentsOfDirectory(atPath: root.appending(path: "art").path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
        let media = Set(((try? fm.contentsOfDirectory(atPath: root.appending(path: "media").path)) ?? [])
            .map { "media/\($0)" } + ((try? fm.contentsOfDirectory(atPath: root.appending(path: "subs").path)) ?? [])
            .map { "subs/\($0)" })
        let before = index
        for stray in index.reconcile(filesOnDisk: media) { try? fm.removeItem(at: root.appending(path: stray)) }
        if index != before { save() }
    }

    /// Builds before per-account folders kept one library at `base` itself.
    /// The first account to sign in after the update takes it over, so
    /// nothing downloaded is fetched again.
    private func adoptFlatLayout(into root: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.appending(path: "index.json").path),
              !fm.fileExists(atPath: root.path) else { return }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["index.json", "media", "art"] {
            try? fm.moveItem(at: base.appending(path: name), to: root.appending(path: name))
        }
    }

    // MARK: - Reading

    /// The file to play instead of streaming, when it is all on disk.
    public func localFile(_ itemId: String) -> URL? {
        guard let root else { return nil }
        return index.readyFile(itemId).map { root.appending(path: $0) }
    }

    /// Whether any of a collection's tracks is transferring right now.
    public func isTransferring(_ collectionId: String) -> Bool {
        index.collection(collectionId)?.trackIds.contains(where: active.contains) ?? false
    }

    public func artFile(_ itemId: String) -> URL? {
        guard let root, art.contains(itemId) else { return nil }
        return root.appending(path: "art/\(itemId).jpg")
    }

    /// A downloaded track, album or playlist as it was saved, gains included.
    public func savedItem(_ id: String) -> JfItem? {
        index.tracks[id]?.item ?? index.collection(id)?.item
    }

    public func isDownloaded(_ collectionId: String) -> Bool { index.collection(collectionId) != nil }

    /// A collection's tracks in order, as saved.
    public func tracks(of collectionId: String) -> [JfItem] {
        (index.collection(collectionId)?.trackIds ?? []).compactMap { index.tracks[$0]?.item }
    }

    // MARK: - Downloading

    /// Saves an album or playlist: its track list, each track's loudness gain
    /// (only single-item fetches carry it, and normalization must work with
    /// no server), the covers, then the files in the background.
    public func download(_ collection: JfItem, client: JellyfinClient) async {
        lastError = nil
        guard owner != nil else { return }
        // Offline the client answers from the downloads themselves.
        guard !paused, await !client.isOffline else {
            lastError = "Downloading needs your server. Turn Offline Mode off first."
            return
        }
        do {
            var list = collection.type == "Playlist"
                ? try await client.tracks(inPlaylist: collection.id)
                : try await client.tracks(inAlbum: collection.id)
            let gains = await Self.singleItems(list.map(\.id), client: client)
            for i in list.indices { list[i].normalizationGain = gains[list[i].id]?.normalizationGain }
            let full = (try? await client.item(id: collection.id)) ?? collection
            let albumIds = Set(list.compactMap(\.albumId))
            let albums = await Self.singleItems(albumIds.sorted(), client: client)
            index.add(full, tracks: list)
            for (id, album) in albums { if let db = album.normalizationGain { index.albumGains[id] = db } }
            save()
            await saveArt([collection.id] + albumIds.subtracting(art).sorted(), client: client)
            await resume(client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Starts whatever is asked for and not yet on disk or on its way:
    /// after a relaunch, a failure, or a new request.
    public func resume(client: JellyfinClient) async {
        lastError = nil
        lastClient = client
        guard let owner, !paused, await !client.isOffline else { return }
        let config = await client.currentConfig
        let running = Set(await session.allTasks.compactMap { OfflineIndex.parseTaskName($0.taskDescription)?.itemId })
        // One video at a time beside music (plan section 8): a film is
        // gigabytes, and a re-encode is the server's GPU for a while.
        var videoBusy = running.contains(where: isVideo)
        for id in index.pending where OfflineIndex.isSafeId(id) && !running.contains(id) {
            if isVideo(id) {
                guard !videoBusy else { continue }
                videoBusy = await startVideo(id, client: client, config: config, owner: owner)
                continue
            }
            guard let url = URL(string: "\(config.url)/Items/\(id)/Download") else { continue }
            var request = URLRequest(url: url)
            request.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                             forHTTPHeaderField: "Authorization")
            // Per request, not on the background session's configuration: that is
            // made once at launch and a header edit must apply to the next download.
            for h in ProxyConnection.shared.headersToSend(for: url) { request.setValue(h.value, forHTTPHeaderField: h.name) }
            let task = session.downloadTask(with: request)
            task.taskDescription = OfflineIndex.taskName(owner: owner, itemId: id)
            task.resume()
        }
        await refreshActive()
    }

    /// Deletes a collection and every file no other collection still uses.
    /// Cancelling one still downloading stops the server's conversion too.
    public func remove(_ collectionId: String) async {
        guard root != nil else { return }
        deleteOrphans(index.remove(collectionId))
        save()
        await cancelUnwanted()
    }

    private func deleteOrphans(_ orphans: [String]) {
        guard let root else { return }
        let fm = FileManager.default
        for file in orphans { try? fm.removeItem(at: root.appending(path: file)) }
        for id in art.subtracting(artIds()) {
            try? fm.removeItem(at: root.appending(path: "art/\(id).jpg"))
            art.remove(id)
        }
    }

    /// Transfers for items nobody wants now: cancelled, and a transcode's
    /// encode on the server stopped.
    private func cancelUnwanted() async {
        guard let owner else { return }
        for task in await session.allTasks {
            guard let name = OfflineIndex.parseTaskName(task.taskDescription), name.owner == owner,
                  index.tracks[name.itemId] == nil else { continue }
            task.cancel()
            transfers[name.itemId] = nil
            if let sessionId = playSessions.removeValue(forKey: name.itemId), let client = lastClient {
                await stopActiveEncoding(client: client, config: await client.currentConfig, playSessionId: sessionId)
            }
        }
        await refreshActive()
    }

    /// Art worth keeping: every collection's, each track's album, and for
    /// video each item's poster or still, its series' and its season's.
    private func artIds() -> Set<String> {
        var ids = Set(index.collections.map(\.id))
        for t in index.tracks.values {
            if let a = t.item.albumId { ids.insert(a) }
            if t.item.type == "Movie" || t.item.type == "Episode" {
                ids.insert(t.item.id)
                if let s = t.item.seriesId { ids.insert(s) }
                if let s = t.item.seasonId { ids.insert(s) }
            }
        }
        return ids
    }

    public func removeAll() async {
        for collection in index.collections { await remove(collection.id) }
    }

    // MARK: - Video

    /// What a downloaded video keeps: its page, the player, the menus,
    /// chapters, resume, and the follow's date check read these.
    public static let videoFields = "Overview,MediaStreams,MediaSources,Genres,Chapters,DateCreated,SortName,OfficialRating,CommunityRating,ProductionYear"

    public enum VideoKind: Sendable { case movie, episode, season, series }

    func isVideo(_ id: String) -> Bool {
        let type = index.tracks[id]?.item.type
        return type == "Movie" || type == "Episode"
    }

    /// Saves a movie, an episode, a season (`item.seriesId` set) or a whole
    /// show. `burnIn`: a picture subtitle burned into a single video.
    /// `follow`: a show fetches new episodes as they arrive.
    public func downloadVideo(_ item: JfItem, kind: VideoKind, follow: Bool = false, burnIn: Int? = nil,
                              client: JellyfinClient) async {
        lastError = nil
        guard owner != nil else { return }
        guard !paused, await !client.isOffline else {
            lastError = "Downloading needs your server. Turn Offline Mode off first."
            return
        }
        let userId = await client.currentConfig.userId
        do {
            var collection = item
            var items: [JfItem]
            var seriesId: String?
            switch kind {
            case .movie, .episode:
                let full: JfItem = try await client.get("/Items/\(item.id)", params: ["userId": userId, "fields": Self.videoFields])
                collection = full
                items = [full]
                seriesId = full.seriesId
            case .season:
                let r: JfItemsResponse = try await client.get("/Shows/\(item.seriesId ?? "")/Episodes", params: [
                    "userId": userId, "seasonId": item.id, "fields": Self.videoFields])
                items = r.items ?? []
                seriesId = item.seriesId
            case .series:
                let r: JfItemsResponse = try await client.get("/Shows/\(item.id)/Episodes", params: [
                    "userId": userId, "fields": Self.videoFields])
                items = r.items ?? []
                seriesId = item.id
            }
            items = items.filter { $0.type == "Movie" || $0.type == "Episode" }
            guard !items.isEmpty else { lastError = "There is nothing to download in that."; return }
            let containers = await Self.containers(seriesId: seriesId, client: client)
            index.add(collection, tracks: items, containers: containers)
            if items.count == 1 { index.setBurnIn(items[0].id, burnIn) }
            if follow { index.setFollow(item.id, on: true, now: Date()) }
            save()
            await saveArt(Array(artIds().subtracting(art)).sorted(), client: client)
            await resume(client: client)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The show and its seasons, so their pages work offline.
    private static func containers(seriesId: String?, client: JellyfinClient) async -> [JfItem] {
        guard let seriesId else { return [] }
        let series = try? await client.item(id: seriesId)
        let seasons = (try? await client.seasons(of: seriesId)) ?? []
        return (series.map { [$0] } ?? []) + seasons
    }

    /// Asks the server how to fetch a video and starts it: the original when
    /// it plays here, else its progressive MP4 (OfflineVideo says which).
    /// Asked afresh at every start: a TranscodingUrl carries the token and a
    /// session that ends, so it is never stored. Answers whether it started.
    private func startVideo(_ id: String, client: JellyfinClient, config: ServerConfig, owner: String) async -> Bool {
        let request = OfflineVideo.Request(userId: config.userId, profile: OfflineVideo.downloadProfile(videoQuality),
                                           burnIn: index.tracks[id]?.burnIn)
        let info: OfflineVideo.Info
        do {
            info = try await client.post("/Items/\(id)/PlaybackInfo", body: request, params: ["UserId": config.userId])
        } catch {
            lastError = error.localizedDescription
            return false
        }
        guard self.owner == owner, let source = info.mediaSources?.first else { return false }
        let outcome = OfflineVideo.outcome(source)
        let url: URL?
        if outcome == .direct {
            url = URL(string: "\(config.url)/Items/\(id)/Download")
        } else if let path = source.transcodingUrl, path.hasPrefix("/"), !path.hasPrefix("//") {
            // Only a path on this server: the token must never go anywhere else.
            url = URL(string: config.url + path)
        } else {
            url = nil
        }
        guard let url else { lastError = "The server offered no way to download this."; return false }
        let runTicks = index.tracks[id]?.item.runTimeTicks
        index.setOutcome(id, outcome)
        save()
        transfers[id] = Transfer(outcome: outcome, estimate: OfflineVideo.estimatedBytes(outcome, source, runTimeTicks: runTicks))
        if outcome != .direct { playSessions[id] = info.playSessionId }
        await saveVideoExtras(id, source: source, client: client)
        var request2 = URLRequest(url: url)
        request2.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                          forHTTPHeaderField: "Authorization")
        for h in ProxyConnection.shared.headersToSend(for: url) { request2.setValue(h.value, forHTTPHeaderField: h.name) }
        let task = session.downloadTask(with: request2)
        // A transcode carries its runtime in its name: the delegate checks the
        // finished file reaches it (it has no length to check).
        task.taskDescription = OfflineIndex.taskName(owner: owner, itemId: id, transcodeRunTicks: outcome == .direct ? nil : runTicks)
        task.resume()
        return true
    }

    /// Text subtitles as WebVTT beside the file, and the media segments. A
    /// failure costs those extras, never the film.
    private func saveVideoExtras(_ id: String, source: OfflineVideo.Source, client: JellyfinClient) async {
        guard let root, let sourceId = source.id, OfflineIndex.isSafeId(sourceId) else { return }
        var subs: [OfflineIndex.Subtitle] = []
        for s in source.mediaStreams ?? [] where s.type == "Subtitle" && s.isTextSubtitleStream == true {
            guard let i = s.index, let data = try? await client.getData("/Videos/\(id)/\(sourceId)/Subtitles/\(i)/0/Stream.vtt"),
                  self.root == root else { continue }
            let file = "subs/\(id).\(i).vtt"
            guard OfflineIndex.isSafeSubtitlePath(file), (try? data.write(to: root.appending(path: file), options: .atomic)) != nil else { continue }
            subs.append(OfflineIndex.Subtitle(index: i, file: file, language: s.language, title: s.displayTitle,
                                              isDefault: s.isDefault, isForced: s.isForced))
        }
        index.setSubtitles(id, subs)
        struct Segments: Decodable {
            struct Item: Decodable { var type: String?; var startTicks: Int?; var endTicks: Int? }
            var items: [Item]?
        }
        if let data = try? await client.getData("/MediaSegments/\(id)"),
           let found = try? JSON.decoder.decode(Segments.self, from: data) {
            index.setSegments(id, (found.items ?? []).compactMap { s in
                guard let type = s.type, let start = s.startTicks, let end = s.endTicks else { return nil }
                return OfflineIndex.Segment(type: type, startTicks: start, endTicks: end)
            })
        }
        save()
    }

    /// A downloaded video's saved subtitles, with their files.
    public func subtitles(of itemId: String) -> [(subtitle: OfflineIndex.Subtitle, url: URL)] {
        guard let root, index.readyFile(itemId) != nil else { return [] }
        return (index.tracks[itemId]?.subs ?? []).map { ($0, root.appending(path: $0.file)) }
    }

    /// "Download new episodes as they arrive", changed after the download.
    public func setFollow(_ seriesId: String, on: Bool) {
        guard owner != nil else { return }
        index.setFollow(seriesId, on: on, now: Date())
        save()
    }

    /// Fetches the new episodes of every followed show. Online only: at
    /// sign-in and when the Downloads screen opens.
    public func syncFollowed(client: JellyfinClient) async {
        guard owner != nil, !paused, await !client.isOffline else { return }
        let userId = await client.currentConfig.userId
        for c in index.collections where c.follow != nil {
            guard let r: JfItemsResponse = try? await client.get("/Shows/\(c.id)/Episodes", params: [
                "userId": userId, "fields": Self.videoFields]) else { continue }
            let fresh = index.newEpisodes(c.id, from: r.items ?? [])
            guard !fresh.isEmpty else { continue }
            index.addToCollection(c.id, fresh)
            for container in await Self.containers(seriesId: c.id, client: client) where container.type == "Season" {
                if index.containers[container.id] == nil { index.containers[container.id] = container }
            }
            save()
        }
        await resume(client: client)
    }

    /// This device played a video to the end.
    public func markWatched(_ itemId: String) {
        guard owner != nil, index.tracks[itemId] != nil else { return }
        index.markWatched(itemId, now: Date())
        save()
    }

    /// "Remove watched episodes": episodes finished over a day ago go.
    /// Answers how many.
    @discardableResult
    public func removeWatched() -> Int {
        guard owner != nil else { return 0 }
        let ids = index.watchedToRemove(now: Date())
        guard !ids.isEmpty else { return 0 }
        deleteOrphans(index.removeTracks(ids))
        save()
        return ids.count
    }

    // MARK: - Offline Mode

    /// Stops every transfer while Offline Mode is on, or allows them again.
    /// Nothing is lost: what was cut off is still pending, and resume()
    /// starts it once the app is back online.
    public func setPaused(_ on: Bool) async {
        paused = on
        guard on else { return }
        for task in await session.allTasks { task.cancel() }
        transfers = [:]
        await refreshActive()
    }

    /// The server's library list (/UserViews), kept so Offline Mode lists
    /// the same libraries.
    public func setLibraries(_ views: [JfItem]) {
        guard owner != nil else { return }
        let before = index
        index.setLibraries(views)
        if index != before { save() }
    }

    /// The signed-in user and their policy, for permissions while offline.
    public func setUser(_ user: OfflineIndex.User?) {
        guard owner != nil, index.user != user else { return }
        index.setUser(user)
        save()
    }

    /// Lyrics found while online, kept with the track for Offline Mode.
    public func setLyrics(_ trackId: String, source: String, synced: Bool, lines: [LyricLine],
                          credit: SpicyCredit? = nil) {
        guard owner != nil else { return }
        index.setLyrics(trackId, source: source, synced: synced, lines: lines, now: Date(), credit: credit)
        save()
    }

    /// Keeps what a lyrics search found for a downloaded track. Nothing, or
    /// an instrumental, is not kept: the next search online may do better.
    public func keepLyrics(_ result: LyricsResult?, for trackId: String) {
        guard let result, !result.instrumental, !result.lines.isEmpty else { return }
        setLyrics(trackId, source: OfflineIndex.StoredLyrics.sourceKey(label: result.source, hasCredit: result.credit != nil),
                  synced: result.synced, lines: result.lines, credit: result.credit)
    }

    /// Moves downloads out of the placeholder libraries: each stored library
    /// is asked which of the unplaced items it holds, 100 ids at a time. Run
    /// online after the library list is stored; offline it does nothing.
    public func placeDownloads(client: JellyfinClient) async {
        guard owner != nil, await !client.isOffline else { return }
        let unplaced = index.unplacedTrackIds
        guard !unplaced.isEmpty else { return }
        let owner = self.owner
        let userId = await client.currentConfig.userId
        // One ancestors request per album, show or movie (placementGroups
        // says why not Ids with ParentId), then fresh copies of its items.
        for (group, ids) in index.placementGroups(unplaced) {
            guard let ancestors: [JfItem] = try? await client.get("/Items/\(group)/Ancestors", params: ["userId": userId]),
                  self.owner == owner, let library = index.library(amongAncestors: ancestors) else { continue }
            for start in stride(from: 0, to: ids.count, by: 100) {
                let chunk = Array(ids[start..<min(start + 100, ids.count)])
                let found: JfItemsResponse? = try? await client.get("/Items", params: [
                    "ids": chunk.joined(separator: ","), "userId": userId,
                    "fields": "Genres,DateCreated,SortName,ProductionYear,Overview,MediaSources",
                ])
                // Signed out or switched account meanwhile: not this index.
                guard self.owner == owner else { return }
                index.refresh(found?.items ?? [])
                index.assignLibrary(chunk, to: library)
                save()
            }
        }
    }

    /// Free and total space on the disk the downloads are on.
    public func diskSpace() -> (free: Int64, total: Int64)? {
        // tvOS has no downloads, and no "important usage" capacity either.
        #if os(tvOS)
        return nil
        #else
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? base.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (free, Int64(total))
        #endif
    }

    // MARK: - Plays made while the server was away

    public func recordPlay(_ itemId: String, userId: String, at date: Date) {
        guard owner != nil else { return }
        index.plays.append(.init(itemId: itemId, userId: userId, date: date))
        save()
        debugLog("offline play of \(itemId) queued, \(index.plays.count) waiting")
    }

    /// Sends queued plays with their real time. Each POST adds one to the
    /// play count, so an entry goes only after the server said yes, and the
    /// first failure stops the run (the server is still away).
    public func replayPlays(client: JellyfinClient) async {
        guard !replaying, !index.plays.isEmpty else { return }
        replaying = true
        defer { replaying = false }
        let userId = await client.currentConfig.userId
        let stamp = ISO8601DateFormatter()
        for play in index.plays where play.userId == userId {
            do {
                try await client.postRaw("/UserPlayedItems/\(play.itemId)", body: Optional<EmptyBody>.none,
                                         params: ["userId": userId, "datePlayed": stamp.string(from: play.date)])
            } catch let error as JellyfinError where OfflineIndex.dropsPlay(afterStatus: error.status) {
                debugLog("offline play of \(play.itemId) refused (HTTP \(error.status)), dropped")
            } catch {
                debugLog("offline play replay stopped: \(error)")
                return
            }
            if let i = index.plays.firstIndex(of: play) { index.plays.remove(at: i) }
            save()
        }
    }

    // MARK: - Internals

    private func save() {
        guard let root, let data = index.encoded() else { return }
        try? data.write(to: root.appending(path: "index.json"), options: .atomic)
        onChange?()
    }

    private func refreshActive() async {
        let owner = self.owner
        active = Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { OfflineIndex.parseTaskName($0.taskDescription) }
            .filter { $0.owner == owner }.map(\.itemId))
    }

    private func handle(_ event: DownloadDelegate.Event) {
        switch event {
        case .progress(let id, let received, let expected):
            var t = transfers[id] ?? Transfer()
            t.received = received
            t.expected = expected
            transfers[id] = t
        case .finished(let taskOwner, let id, let file, let bytes):
            active.remove(id)
            transfers[id] = nil
            playSessions[id] = nil
            if taskOwner == owner, index.tracks[id] != nil {
                index.markReady(id, file: file, bytes: bytes, now: Date())
                save()
                // The next video waits for this one.
                if isVideo(id), let client = lastClient { Task { await resume(client: client) } }
            } else {
                // Removed while it downloaded, or its account signed out.
                try? FileManager.default.removeItem(at: base.appending(path: taskOwner).appending(path: file))
            }
        case .failed(let id, let message):
            active.remove(id)
            transfers[id] = nil
            playSessions[id] = nil
            lastError = message
            debugLog("download of \(id) failed: \(message)")
        case .eventsDelivered:
            if let handler = Self.backgroundCompletion {
                Self.backgroundCompletion = nil
                handler()
            } else {
                Self.deliveredWithoutHandler = true
            }
        }
    }

    private func saveArt(_ ids: [String], client: JellyfinClient) async {
        guard let root else { return }
        for id in ids where !art.contains(id) && OfflineIndex.isSafeId(id) {
            guard let url = await client.imageUrl(itemId: id, size: 600),
                  let (data, response) = try? await ProxyConnection.shared.session(for: url).data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            guard self.root == root else { return }
            if (try? data.write(to: root.appending(path: "art/\(id).jpg"), options: .atomic)) != nil { art.insert(id) }
        }
    }

    /// Single-item fetches, a few at a time: a long playlist is hundreds.
    private static func singleItems(_ ids: [String], client: JellyfinClient) async -> [String: JfItem] {
        var out: [String: JfItem] = [:]
        for start in stride(from: 0, to: ids.count, by: 8) {
            await withTaskGroup(of: JfItem?.self) { group in
                for id in ids[start..<min(start + 8, ids.count)] {
                    group.addTask { try? await client.item(id: id) }
                }
                for await item in group { if let item { out[item.id] = item } }
            }
        }
        return out
    }
}

/// The background session's delegate. Its own nonisolated class: URLSession
/// calls it on a queue of its own, and the downloaded temp file is deleted the
/// moment didFinishDownloadingTo returns, so the move happens right here and
/// only the result hops to the main actor.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(id: String, received: Int64, expected: Int64?)
        case finished(owner: String, id: String, file: String, bytes: Int)
        case failed(id: String, message: String)
        case eventsDelivered
    }

    let base: URL
    /// Set once, before the session that calls this is created.
    var onEvent: (@Sendable (Event) -> Void)?
    /// When each transfer last said how far it got: a few times a second is
    /// plenty. URLSession calls this delegate on one serial queue.
    private var lastProgress: [Int: Date] = [:]

    init(base: URL) { self.base = base }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = OfflineIndex.parseTaskName(downloadTask.taskDescription) else { return }
        let now = Date()
        if let last = lastProgress[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 0.5 { return }
        lastProgress[downloadTask.taskIdentifier] = now
        onEvent?(.progress(id: name.itemId, received: totalBytesWritten,
                           expected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // A task from a build before per-account folders has no owner: it is
        // dropped, and resume asks again under the account that signs in.
        guard let name = OfflineIndex.parseTaskName(downloadTask.taskDescription) else { return }
        let root = base.appending(path: name.owner, directoryHint: .isDirectory)
        lastProgress[downloadTask.taskIdentifier] = nil
        onEvent?(Self.place(location, owner: name.owner, id: name.itemId, response: downloadTask.response, root: root,
                            transcodeRunTicks: OfflineIndex.transcodeRunTicks(downloadTask.taskDescription)))
    }

    /// A background download "finishes" on any response, error pages
    /// included, so the status and length are checked before the bytes are
    /// trusted as a track.
    static func place(_ location: URL, owner: String, id: String, response: URLResponse?, root: URL,
                      transcodeRunTicks: Int? = nil) -> Event {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return .failed(id: id, message: status == 403
                ? "The server does not allow this account to download. An admin can turn on media downloading for it."
                : "The server answered HTTP \(status).")
        }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let expected = response?.expectedContentLength ?? -1
        guard size > 0, expected < 0 || Int64(size) == expected else {
            return .failed(id: id, message: "A download was cut short.")
        }
        guard let ext = OfflineIndex.fileExtension(suggestedFilename: http?.suggestedFilename, mimeType: http?.mimeType) else {
            return .failed(id: id, message: "The server sent something that is not a media file.")
        }
        if let runTicks = transcodeRunTicks {
            // No length to check: the last fragment must reach the end, or the
            // server stopped partway (a full transcode folder once did that).
            guard let handle = try? FileHandle(forUpdating: location) else { return .failed(id: id, message: "A download was cut short.") }
            defer { try? handle.close() }
            let read: (Int, Int) -> [UInt8] = { offset, length in
                (try? handle.seek(toOffset: UInt64(offset))).flatMap { _ in try? handle.read(upToCount: length) }.map(Array.init) ?? []
            }
            guard OfflineVideo.isWholeTranscode(endSeconds: OfflineVideo.fragmentedEndSeconds(read: read, fileSize: size),
                                                runTimeTicks: runTicks) else {
                return .failed(id: id, message: "The server stopped converting partway. Try again.")
            }
            // Jellyfin tags HEVC hev1 here, which AVFoundation will not open.
            for offset in OfflineVideo.hvc1RetagOffsets(read: read, fileSize: size) {
                try? handle.seek(toOffset: UInt64(offset))
                try? handle.write(contentsOf: Data("hvc1".utf8))
            }
        }
        let file = "media/\(id).\(ext)"
        guard OfflineIndex.isSafeMediaPath(file) else { return .failed(id: id, message: "Bad item id.") }
        let dest = root.appending(path: file)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            return .failed(id: id, message: error.localizedDescription)
        }
        return .finished(owner: owner, id: id, file: file, bytes: size)
    }

    /// A server that wants a client certificate asks the background session too.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ProxyConnection.shared.respond(to: challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = OfflineIndex.parseTaskName(task.taskDescription),
              (error as? URLError)?.code != .cancelled else { return }
        onEvent?(.failed(id: name.itemId, message: error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEvent?(.eventsDelivered)
    }
}
