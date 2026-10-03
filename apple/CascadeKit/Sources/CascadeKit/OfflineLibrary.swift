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
/// Layout, all relative to `root` (Application Support, excluded from
/// backup; Caches would be purged under storage pressure):
///   index.json          OfflineIndex
///   media/<id>.<ext>    one file per track, shared between collections
///   art/<id>.jpg        600 px covers for collections and their albums
@MainActor
@Observable
public final class OfflineLibrary {
    public private(set) var index: OfflineIndex
    /// Tracks with a transfer in flight, for progress on the Downloads screen.
    public private(set) var active: Set<String> = []
    public private(set) var lastError: String?
    /// Items with a cover on disk.
    private var art: Set<String>

    public let root: URL
    @ObservationIgnored private let delegate: DownloadDelegate
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var replaying = false

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

    public init(root: URL = OfflineLibrary.defaultRoot) {
        self.root = root
        let fm = FileManager.default
        for dir in ["media", "art"] {
            try? fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)

        index = OfflineIndex.decode(try? Data(contentsOf: root.appending(path: "index.json")))
        art = Set(((try? fm.contentsOfDirectory(atPath: root.appending(path: "art").path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
        delegate = DownloadDelegate(root: root)

        let media = Set(((try? fm.contentsOfDirectory(atPath: root.appending(path: "media").path)) ?? [])
            .map { "media/\($0)" })
        let before = index
        for stray in index.reconcile(filesOnDisk: media) { try? fm.removeItem(at: root.appending(path: stray)) }
        if index != before { save() }

        // Set before the session exists, so no callback can arrive without it.
        delegate.onEvent = { [weak self] event in Task { @MainActor in self?.handle(event) } }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        Task { await refreshActive() }
    }

    // MARK: - Reading

    /// The file to play instead of streaming, when it is all on disk.
    public func localFile(_ itemId: String) -> URL? {
        index.readyFile(itemId).map { root.appending(path: $0) }
    }

    /// Whether any of a collection's tracks is transferring right now.
    public func isTransferring(_ collectionId: String) -> Bool {
        index.collection(collectionId)?.trackIds.contains(where: active.contains) ?? false
    }

    public func artFile(_ itemId: String) -> URL? {
        art.contains(itemId) ? root.appending(path: "art/\(itemId).jpg") : nil
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
        let config = await client.currentConfig
        let running = Set(await session.allTasks.compactMap(\.taskDescription))
        for id in index.pending where !running.contains(id) && OfflineIndex.isSafeId(id) {
            guard let url = URL(string: "\(config.url)/Items/\(id)/Download") else { continue }
            var request = URLRequest(url: url)
            request.setValue(authHeader(appVersion: cascadeAppVersion, deviceId: config.deviceId, token: config.token),
                             forHTTPHeaderField: "Authorization")
            let task = session.downloadTask(with: request)
            task.taskDescription = id
            task.resume()
        }
        await refreshActive()
    }

    /// Deletes a collection and every file no other collection still uses.
    public func remove(_ collectionId: String) async {
        let orphans = index.remove(collectionId)
        save()
        let fm = FileManager.default
        for file in orphans { try? fm.removeItem(at: root.appending(path: file)) }
        let wantedArt = Set(index.collections.map(\.id) + index.tracks.values.compactMap(\.item.albumId))
        for id in art.subtracting(wantedArt) {
            try? fm.removeItem(at: root.appending(path: "art/\(id).jpg"))
            art.remove(id)
        }
        for task in await session.allTasks where index.tracks[task.taskDescription ?? ""] == nil {
            task.cancel()
        }
        await refreshActive()
    }

    public func removeAll() async {
        for collection in index.collections { await remove(collection.id) }
    }

    // MARK: - Plays made while the server was away

    public func recordPlay(_ itemId: String, userId: String, at date: Date) {
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
        guard let data = index.encoded() else { return }
        try? data.write(to: root.appending(path: "index.json"), options: .atomic)
    }

    private func refreshActive() async {
        active = Set(await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap(\.taskDescription))
    }

    private func handle(_ event: DownloadDelegate.Event) {
        switch event {
        case .finished(let id, let file, let bytes):
            active.remove(id)
            if index.tracks[id] != nil {
                index.markReady(id, file: file, bytes: bytes)
                save()
            } else {
                // Removed while it downloaded.
                try? FileManager.default.removeItem(at: root.appending(path: file))
            }
        case .failed(let id, let message):
            active.remove(id)
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
        for id in ids where !art.contains(id) && OfflineIndex.isSafeId(id) {
            guard let url = await client.imageUrl(itemId: id, size: 600),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
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
        case finished(id: String, file: String, bytes: Int)
        case failed(id: String, message: String)
        case eventsDelivered
    }

    let root: URL
    /// Set once, before the session that calls this is created.
    var onEvent: (@Sendable (Event) -> Void)?

    init(root: URL) { self.root = root }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        onEvent?(Self.place(location, id: id, response: downloadTask.response, root: root))
    }

    /// A background download "finishes" on any response, error pages
    /// included, so the status and length are checked before the bytes are
    /// trusted as a track.
    static func place(_ location: URL, id: String, response: URLResponse?, root: URL) -> Event {
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
            return .failed(id: id, message: "The server sent something that is not a music file.")
        }
        let file = "media/\(id).\(ext)"
        guard OfflineIndex.isSafeMediaPath(file) else { return .failed(id: id, message: "Bad item id.") }
        let dest = root.appending(path: file)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            return .failed(id: id, message: error.localizedDescription)
        }
        return .finished(id: id, file: file, bytes: size)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription,
              (error as? URLError)?.code != .cancelled else { return }
        onEvent?(.failed(id: id, message: error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEvent?(.eventsDelivered)
    }
}
