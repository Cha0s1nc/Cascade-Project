import Foundation
import Testing
@testable import CascadeKit

struct OfflineIndexTests {
    private func track(_ id: String) -> JfItem { JfItem(id: id, name: id, type: "Audio") }
    private func album(_ id: String) -> JfItem { JfItem(id: id, name: id, type: "MusicAlbum") }

    @Test func aSharedTrackOutlivesTheFirstCollectionRemoved() {
        var index = OfflineIndex()
        index.add(album("a"), tracks: [track("1"), track("2")])
        index.add(JfItem(id: "p", name: "p", type: "Playlist"), tracks: [track("2"), track("3")])
        for id in ["1", "2", "3"] { index.markReady(id, file: "media/\(id).flac", bytes: 10) }
        #expect(index.totalBytes == 30)

        #expect(index.remove("a") == ["media/1.flac"])
        #expect(index.readyFile("2") == "media/2.flac")
        #expect(index.remove("p") == ["media/2.flac", "media/3.flac"])
        #expect(index.tracks.isEmpty)
    }

    @Test func albumGainsGoWithTheLastTrackFromThatAlbum() {
        var index = OfflineIndex()
        var one = track("1"); one.albumId = "A"
        var two = track("2"); two.albumId = "B"
        index.add(album("x"), tracks: [one])
        index.add(album("y"), tracks: [two])
        index.albumGains = ["A": -3, "B": -5]
        index.remove("x")
        #expect(index.albumGains == ["B": -5])
    }

    @Test func aRefusedPlayIsDroppedOnlyWhenRetryingCannotHelp() {
        #expect(OfflineIndex.dropsPlay(afterStatus: 404))
        #expect(OfflineIndex.dropsPlay(afterStatus: 400))
        for keep in [0, 401, 403, 500, 502, 503] { #expect(!OfflineIndex.dropsPlay(afterStatus: keep), "\(keep)") }
    }

    @Test func onlyPlainIdsBecomeFileNames() {
        #expect(OfflineIndex.isSafeId("4489a27fb2adcc74f790cb3d3d977ef7"))
        for bad in ["", "../x", "a/b", "a.b", "é", String(repeating: "a", count: 65)] {
            #expect(!OfflineIndex.isSafeId(bad), "\(bad)")
        }
    }

    @Test func askingAgainKeepsWhatIsOnDiskAndPutsItFirst() {
        var index = OfflineIndex()
        index.add(album("a"), tracks: [track("1")])
        index.markReady("1", file: "media/1.m4a", bytes: 5)
        index.add(album("b"), tracks: [track("9")])
        index.add(album("a"), tracks: [track("1"), track("2")])
        #expect(index.collections.map(\.id) == ["a", "b"])
        #expect(index.readyFile("1") == "media/1.m4a")
        #expect(index.pending == ["9", "2"])   // oldest request first
        #expect(index.progress("a") == (1, 2))
    }

    @Test func pendingListsASharedTrackOnce() {
        var index = OfflineIndex()
        index.add(album("a"), tracks: [track("1"), track("2")])
        index.add(album("b"), tracks: [track("2"), track("3")])
        #expect(index.pending == ["1", "2", "3"])
    }

    @Test func reconcileRequeuesMissingFilesAndReportsStrays() {
        var index = OfflineIndex()
        index.add(album("a"), tracks: [track("1"), track("2")])
        index.markReady("1", file: "media/1.flac", bytes: 10)
        index.markReady("2", file: "media/2.flac", bytes: 10)
        let strays = index.reconcile(filesOnDisk: ["media/2.flac", "media/old.flac"])
        #expect(strays == ["media/old.flac"])
        #expect(index.readyFile("1") == nil)
        #expect(index.pending == ["1"])
        #expect(index.totalBytes == 10)
    }

    @Test func decodeDropsPathsThatLeaveTheFolderAndSurvivesGarbage() throws {
        var index = OfflineIndex()
        index.add(album("a"), tracks: [track("1"), track("2")])
        index.markReady("1", file: "media/../../Documents/x", bytes: 1)
        index.markReady("2", file: "media/2.flac", bytes: 1)
        let back = OfflineIndex.decode(index.encoded())
        #expect(back.readyFile("1") == nil)
        #expect(back.readyFile("2") == "media/2.flac")
        #expect(OfflineIndex.decode(Data("not json".utf8)) == OfflineIndex())
        #expect(OfflineIndex.decode(nil) == OfflineIndex())
        for bad in ["/etc/passwd", "media/", "media/.hidden", "media/a/b.flac", "art/1.jpg"] {
            #expect(!OfflineIndex.isSafeMediaPath(bad), "\(bad)")
        }
    }

    @Test func extensionComesFromTheFileNameThenTheMimeType() {
        #expect(OfflineIndex.fileExtension(suggestedFilename: "01 - Song.FLAC", mimeType: "audio/flac") == "flac")
        #expect(OfflineIndex.fileExtension(suggestedFilename: nil, mimeType: "audio/mpeg") == "mp3")
        #expect(OfflineIndex.fileExtension(suggestedFilename: "Download", mimeType: "audio/mp4") != nil)
        #expect(OfflineIndex.fileExtension(suggestedFilename: "x.a b", mimeType: "text/html") == nil)
        #expect(OfflineIndex.fileExtension(suggestedFilename: nil, mimeType: nil) == nil)
        // A file name only counts when it names audio: an error page a proxy
        // answered 200 with is not a track, whatever it is called.
        #expect(OfflineIndex.fileExtension(suggestedFilename: "login.html", mimeType: "text/html") == nil)
        #expect(OfflineIndex.fileExtension(suggestedFilename: "track.mp3", mimeType: "text/html") == "mp3")
    }

    @Test func onlyAWholeAudioResponseBecomesATrack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func temp() throws -> URL {
            let url = root.appending(path: UUID().uuidString)
            try Data(repeating: 1, count: 10).write(to: url)
            return url
        }
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x/Items/abc/Download")!, statusCode: status,
                            httpVersion: nil, headerFields: headers)!
        }
        let flac = ["Content-Type": "audio/flac", "Content-Disposition": "attachment; filename=\"01 Song.flac\""]

        if case .failed(_, let message) = DownloadDelegate.place(try temp(), owner: "u1", id: "abc", response: response(403, [:]), root: root) {
            #expect(message.contains("admin"))
        } else { Issue.record("a 403 page was kept") }
        guard case .failed = DownloadDelegate.place(try temp(), owner: "u1", id: "abc",
            response: response(200, flac.merging(["Content-Length": "99"]) { $1 }), root: root) else {
            Issue.record("a short file was kept"); return
        }
        let ok = DownloadDelegate.place(try temp(), owner: "u1", id: "abc",
                                        response: response(200, flac.merging(["Content-Length": "10"]) { $1 }), root: root)
        guard case .finished(let owner, _, let file, let bytes) = ok else { Issue.record("\(ok)"); return }
        #expect(owner == "u1" && file == "media/abc.flac" && bytes == 10)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: file).path))
    }

    @Test func accountsAndTaskNames() {
        #expect(OfflineIndex.isSafeUserId("4f1c2a9e8b7d4c3e9a1b2c3d4e5f6a7b"))
        #expect(OfflineIndex.isSafeUserId("4f1c2a9e-8b7d-4c3e-9a1b-2c3d4e5f6a7b"))
        for bad in ["", "-", "---", "..", "a/b", ".hidden", String(repeating: "x", count: 65)] {
            #expect(!OfflineIndex.isSafeUserId(bad), "\(bad)")
        }
        let name = OfflineIndex.taskName(owner: "u-1", itemId: "abc123")
        #expect(OfflineIndex.parseTaskName(name)?.owner == "u-1")
        #expect(OfflineIndex.parseTaskName(name)?.itemId == "abc123")
        // A task from before per-account folders carries only the track.
        #expect(OfflineIndex.parseTaskName("abc123") == nil)
        #expect(OfflineIndex.parseTaskName("../x/abc") == nil)
        #expect(OfflineIndex.parseTaskName(nil) == nil)
    }
}
