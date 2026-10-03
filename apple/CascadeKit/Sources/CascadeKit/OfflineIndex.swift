import Foundation
import UniformTypeIdentifiers

// What is downloaded, as one value: the single source of truth for offline
// playback (Finamp's lesson: one index, not several stores kept in step by
// hand). Pure, so the rules that decide what a removal may delete are
// tested here; OfflineLibrary owns the files and the one copy on disk.
//
// Paths are relative to the offline folder: the app container's absolute
// path changes on every install.

public struct OfflineIndex: Codable, Sendable, Equatable {
    public struct Track: Codable, Sendable, Equatable {
        /// The single-item fetch, so it carries the loudness gain the list
        /// queries leave out and normalization works with no server.
        public var item: JfItem
        /// "media/<id>.<ext>" once the whole file is on disk; nil until then.
        public var file: String?
        public var bytes: Int = 0
    }

    /// An album or playlist the user asked for. A track shared by two of
    /// them is stored once.
    public struct Collection: Codable, Sendable, Equatable, Identifiable {
        public var item: JfItem
        public var trackIds: [String]
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

    public var tracks: [String: Track] = [:]
    /// Newest first.
    public var collections: [Collection] = []
    public var plays: [Play] = []
    /// Album loudness gains (dB) for the albums downloaded tracks belong to,
    /// so album-mode normalization works offline, and for a playlist's
    /// tracks too. Only albums that have one.
    public var albumGains: [String: Double] = [:]

    public init() {}

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

    /// Every file a ready track points at.
    public var files: Set<String> { Set(tracks.values.compactMap(\.file)) }

    // MARK: - Changing

    /// Asks for a collection. Asking again refreshes its track list; tracks
    /// already on disk are kept, not fetched twice.
    public mutating func add(_ collection: JfItem, tracks list: [JfItem]) {
        collections.removeAll { $0.id == collection.id }
        collections.insert(Collection(item: collection, trackIds: list.map(\.id)), at: 0)
        for track in list {
            if var existing = tracks[track.id] {
                existing.item = track
                tracks[track.id] = existing
            } else {
                tracks[track.id] = Track(item: track)
            }
        }
    }

    public mutating func markReady(_ trackId: String, file: String, bytes: Int) {
        tracks[trackId]?.file = file
        tracks[trackId]?.bytes = bytes
    }

    /// Drops a collection, and with it every track no other collection
    /// still holds. Returns the files that are now nobody's, to delete.
    @discardableResult
    public mutating func remove(_ collectionId: String) -> [String] {
        collections.removeAll { $0.id == collectionId }
        let kept = Set(collections.flatMap(\.trackIds))
        var orphaned: [String] = []
        for (id, track) in tracks where !kept.contains(id) {
            if let file = track.file { orphaned.append(file) }
            tracks[id] = nil
        }
        let albums = Set(tracks.values.compactMap(\.item.albumId))
        albumGains = albumGains.filter { albums.contains($0.key) }
        return orphaned.sorted()
    }

    /// Brings the index in line with the disk after a crash, a relaunch or a
    /// user poking at the container: a ready track whose file is gone goes
    /// back to pending. Returns files on disk the index does not know, to
    /// delete (a download finished after its collection was removed).
    public mutating func reconcile(filesOnDisk: Set<String>) -> [String] {
        for (id, track) in tracks {
            if let file = track.file, !filesOnDisk.contains(file) {
                tracks[id]?.file = nil
                tracks[id]?.bytes = 0
            }
        }
        return filesOnDisk.subtracting(files).sorted()
    }

    // MARK: - Storage

    /// A stored index, validated: it is read from disk, where anything can
    /// be. A path that could leave the offline folder is dropped, and an
    /// unreadable file is an empty index rather than a crash.
    public static func decode(_ data: Data?) -> OfflineIndex {
        guard let data, var index = try? JSONDecoder().decode(OfflineIndex.self, from: data) else { return OfflineIndex() }
        for (id, track) in index.tracks where track.file.map(isSafeMediaPath) == false {
            index.tracks[id]?.file = nil
            index.tracks[id]?.bytes = 0
        }
        let known = Set(index.tracks.keys)
        for i in index.collections.indices {
            index.collections[i].trackIds.removeAll { !known.contains($0) }
        }
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
    public static func taskName(owner: String, itemId: String) -> String { "\(owner)/\(itemId)" }

    public static func parseTaskName(_ name: String?) -> (owner: String, itemId: String)? {
        let parts = (name ?? "").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, isSafeUserId(parts[0]), isSafeId(parts[1]) else { return nil }
        return (parts[0], parts[1])
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
