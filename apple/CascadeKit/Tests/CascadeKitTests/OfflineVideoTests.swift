import Foundation
import Testing
@testable import CascadeKit

// Video downloads: the profile, the outcome (the fixture shared with the
// desktop's test/offline-video.test.ts, recorded from jellyfin12), the size
// estimate, the truncation check and the hvc1 retag, then the catalog's
// follow, remove-watched and placement rules, and the WebVTT reader.
struct OfflineVideoTests {
    static let repo = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    struct Case: Decodable {
        var name: String
        var runTimeTicks: Int
        var source: OfflineVideo.Source
        var outcome: String
    }
    struct Fixture: Decodable { var cases: [Case] }

    static func fixture() throws -> Fixture {
        try JSON.decoder.decode(Fixture.self, from: Data(contentsOf: repo.appending(path: "test/fixtures/offline-video.json")))
    }

    static let fmp4: [UInt8] = Array((try? Data(contentsOf: repo.appending(path: "test/fixtures/offline-fragmented.mp4"))) ?? Data())
    static func reader(_ b: [UInt8]) -> (Int, Int) -> [UInt8] {
        { offset, length in offset >= b.count ? [] : Array(b[offset..<min(b.count, offset + length)]) }
    }

    @Test func outcomesMatchTheDesktopFixture() throws {
        let cases = try Self.fixture().cases
        #expect(cases.count >= 11)
        for c in cases {
            #expect(OfflineVideo.outcome(c.source).rawValue == c.outcome, "\(c.name)")
        }
    }

    @Test func theProfileKeepsDirectPlayAndAddsOneProgressiveMP4() {
        let p = OfflineVideo.downloadProfile(.original)
        #expect(p.maxStreamingBitrate == OfflineVideo.maxBitrate)
        #expect(p.directPlayProfiles.allSatisfy { $0.type == .video })
        #expect(p.transcodingProfiles.count == 1)
        #expect(p.transcodingProfiles[0].streamProtocol == "http" && p.transcodingProfiles[0].context == "Streaming")
        #expect(p.transcodingProfiles[0].videoCodec == "h264,hevc")
        #expect(p.codecProfiles?.contains { $0.codec == "hevc" } == true)
        #expect(p.codecProfiles?.contains { $0.conditions.contains { $0.property == "Height" } } == false)
        let capped = OfflineVideo.downloadProfile(.p720).codecProfiles?.last
        #expect(capped?.codec == nil)
        #expect(capped?.conditions == [ProfileCondition(condition: "LessThanEqual", property: "Height", value: "720", isRequired: true)])
        // On the wire: PascalCase, no codec key for "every codec", and no
        // SubtitleStreamIndex unless something is burned in.
        let body = String(decoding: try! JSON.encoder.encode(OfflineVideo.Request(userId: "u", profile: OfflineVideo.downloadProfile(.p720), burnIn: nil)), as: UTF8.self)
        #expect(body.contains("\"CodecProfiles\"") && body.contains("\"MaxStreamingBitrate\":400000000"))
        #expect(!body.contains("SubtitleStreamIndex"))
        let burn = String(decoding: try! JSON.encoder.encode(OfflineVideo.Request(userId: "u", profile: OfflineVideo.downloadProfile(.original), burnIn: 3)), as: UTF8.self)
        #expect(burn.contains("\"SubtitleStreamIndex\":3"))
    }

    @Test func storedQualityReadsBack() {
        #expect(VideoQuality(stored: "720p", fallback: .original) == .p720)
        #expect(VideoQuality(stored: "4k", fallback: .p1080) == .p1080)
        #expect(VideoQuality(stored: nil, fallback: .original) == .original)
    }

    @Test func estimates() throws {
        let cases = try Self.fixture().cases
        let remux = cases.first { $0.name == "hevc-mkv-apple" }!
        #expect(OfflineVideo.estimatedBytes(.remux, remux.source, runTimeTicks: remux.runTimeTicks) == remux.source.size)
        let cap = cases.first { $0.name == "cap720-of-1080" }!
        #expect(OfflineVideo.estimatedBytes(.reencode, cap.source, runTimeTicks: cap.runTimeTicks) == 3_656_250_000)
        #expect(OfflineVideo.secondsLeft(received: 500, estimate: 1000, bytesPerSecond: 100) == 5)
        #expect(OfflineVideo.secondsLeft(received: 500, estimate: nil, bytesPerSecond: 100) == nil)
        #expect(OfflineVideo.isWatched(positionTicks: 90, runTimeTicks: 100))
        #expect(!OfflineVideo.isWatched(positionTicks: 89, runTimeTicks: 100))
    }

    @Test func theEndOfAFragmentedFileIsItsLastWholeFragment() {
        #expect(!Self.fmp4.isEmpty)
        let end = OfflineVideo.fragmentedEndSeconds(read: Self.reader(Self.fmp4), fileSize: Self.fmp4.count)
        #expect(end.map { abs($0 - 3.0) < 0.05 } == true, "got \(String(describing: end))")
        #expect(OfflineVideo.isWholeTranscode(endSeconds: end, runTimeTicks: 30_000_000))
        // Cut inside the last fragment's samples.
        let cut = Array(Self.fmp4.prefix(13_000))
        let short = OfflineVideo.fragmentedEndSeconds(read: Self.reader(cut), fileSize: cut.count)
        #expect(short.map { $0 < 2.5 } == true)
        #expect(!OfflineVideo.isWholeTranscode(endSeconds: short, runTimeTicks: 6_000_000_000))
        let bare = Array(Self.fmp4.prefix(3_800))
        #expect(OfflineVideo.fragmentedEndSeconds(read: Self.reader(bare), fileSize: bare.count) == nil)
        #expect(!OfflineVideo.isWholeTranscode(endSeconds: nil, runTimeTicks: 30_000_000))
        #expect(OfflineVideo.isWholeTranscode(endSeconds: nil, runTimeTicks: nil))
    }

    @Test func hev1IsFoundInTheSampleEntryAndOnlyThere() {
        let offsets = OfflineVideo.hvc1RetagOffsets(read: Self.reader(Self.fmp4), fileSize: Self.fmp4.count)
        #expect(offsets.count == 1)
        if let o = offsets.first { #expect(Array(Self.fmp4[o..<o + 4]) == Array("hev1".utf8)) }
        var patched = Self.fmp4
        for o in offsets { patched.replaceSubrange(o..<o + 4, with: Array("hvc1".utf8)) }
        #expect(OfflineVideo.hvc1RetagOffsets(read: Self.reader(patched), fileSize: patched.count).isEmpty)
    }

    // MARK: Catalog

    static func ep(_ id: String, created: Date? = nil, played: Bool? = nil, lastPlayed: Date? = nil) -> JfItem {
        var e = JfItem(id: id, name: id, type: "Episode", userData: JfUserData(played: played))
        e.seriesId = "show"
        e.seasonId = "s1"
        e.dateCreated = created.map { ISO8601DateFormatter().string(from: $0) }
        e.userData?.lastPlayedDate = lastPlayed.map { ISO8601DateFormatter().string(from: $0) }
        return e
    }
    static let series = JfItem(id: "show", name: "Show", type: "Series")
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aFollowedSeriesFetchesOnlyNewUnwatchedEpisodes() {
        var index = OfflineIndex()
        index.add(Self.series, tracks: [Self.ep("e1"), Self.ep("e2")])
        let later = Self.t0.addingTimeInterval(60)
        #expect(index.newEpisodes("show", from: [Self.ep("e3", created: later)]).isEmpty, "not followed")
        index.setFollow("show", on: true, now: Self.t0)
        let server = [
            Self.ep("e1", created: later), Self.ep("old", created: Self.t0.addingTimeInterval(-60)),
            Self.ep("seen", created: later, played: true), Self.ep("e3", created: later),
        ]
        #expect(index.newEpisodes("show", from: server).map(\.id) == ["e3"])
        index.addToCollection("show", [server[3]])
        #expect(index.collection("show")?.trackIds == ["e1", "e2", "e3"])
        index.setFollow("show", on: false, now: Self.t0)
        #expect(index.collection("show")?.follow == nil)
    }

    @Test func removeWatchedNeverComesBackThroughTheFollow() {
        var index = OfflineIndex()
        let fresh = Self.t0.addingTimeInterval(60)
        index.add(Self.series, tracks: [Self.ep("e1", created: fresh)])
        index.setFollow("show", on: true, now: Self.t0)
        index.markReady("e1", file: "media/e1.mp4", bytes: 10, now: fresh)
        index.markWatched("e1", now: fresh.addingTimeInterval(10))
        #expect(index.watchedToRemove(now: fresh.addingTimeInterval(OfflineIndex.removeWatchedAfter)).isEmpty)
        #expect(index.watchedToRemove(now: fresh.addingTimeInterval(10 + OfflineIndex.removeWatchedAfter)) == ["e1"])
        #expect(index.removeTracks(["e1"]) == ["media/e1.mp4"])
        #expect(index.collection("show")?.trackIds == [])
        #expect(index.newEpisodes("show", from: [Self.ep("e1", created: fresh), Self.ep("e2", created: fresh)]).map(\.id) == ["e2"])
        let back = OfflineIndex.decode(index.encoded())
        #expect(back.collection("show")?.skip == ["e1"])
        #expect(back.collection("show")?.follow == Self.t0)
    }

    @Test func watchedOnTheServerCountsOnlyAfterTheDownload() {
        var index = OfflineIndex()
        index.add(JfItem(id: "s1", name: "S1", type: "Season"), tracks: [
            Self.ep("before", played: true, lastPlayed: Self.t0.addingTimeInterval(-60)),
            Self.ep("after", played: true, lastPlayed: Self.t0.addingTimeInterval(60)),
        ])
        index.add(JfItem(id: "film", name: "Film", type: "Movie"), tracks: [JfItem(id: "film", name: "Film", type: "Movie")])
        for id in ["before", "after", "film"] { index.markReady(id, file: "media/\(id).mp4", bytes: 10, now: Self.t0) }
        index.markWatched("film", now: Self.t0)
        #expect(index.watchedToRemove(now: Self.t0.addingTimeInterval(2 * OfflineIndex.removeWatchedAfter)) == ["after"])
        index.removeTracks(["before", "after"])
        #expect(index.collection("s1") == nil)
        #expect(index.collection("film") != nil)
    }

    @Test func newTrackFieldsSurviveAWriteAndARead() {
        var index = OfflineIndex()
        index.add(JfItem(id: "film", name: "Film", type: "Movie"), tracks: [JfItem(id: "film", name: "Film", type: "Movie")])
        index.markReady("film", file: "media/film.mp4", bytes: 10, now: Self.t0)
        index.setOutcome("film", .remux)
        index.setBurnIn("film", 3)
        let back = OfflineIndex.decode(index.encoded())
        #expect(back.tracks["film"]?.readyAt == Self.t0)
        #expect(back.tracks["film"]?.outcome == .remux)
        #expect(back.tracks["film"]?.burnIn == 3)
        // A single episode is a collection of its own, kept on a read.
        index.add(Self.ep("solo"), tracks: [Self.ep("solo")])
        #expect(OfflineIndex.decode(index.encoded()).collection("solo") != nil)
    }

    @Test func placementAsksOncePerAlbumOrShow() {
        var index = OfflineIndex()
        index.setLibraries([JfItem(id: "libmusic", name: "Music", collectionType: "music"),
                            JfItem(id: "libtv", name: "TV Shows", collectionType: "tvshows")])
        var t1 = JfItem(id: "t1", type: "Audio"); t1.albumId = "album"
        var t2 = JfItem(id: "t2", type: "Audio"); t2.albumId = "album"
        index.add(JfItem(id: "album", type: "MusicAlbum"), tracks: [t1, t2])
        index.add(Self.series, tracks: [Self.ep("e1"), Self.ep("e2")])
        let groups = index.placementGroups(index.unplacedTrackIds)
        #expect(Dictionary(uniqueKeysWithValues: groups.map { ($0.group, $0.ids) }) == ["album": ["t1", "t2"], "show": ["e1", "e2"]])
        // As jellyfin12 answered for an episode: season, show, library, root.
        let ancestors = [JfItem(id: "s3", type: "Season"), JfItem(id: "show", type: "Series"),
                         JfItem(id: "libtv", type: "CollectionFolder"), JfItem(id: "root", type: "UserRootFolder")]
        #expect(index.library(amongAncestors: ancestors) == "libtv")
        #expect(index.library(amongAncestors: [JfItem(id: "root")]) == nil)
    }

    @Test func aTranscodesTaskNameCarriesItsRuntime() {
        let name = OfflineIndex.taskName(owner: "u1", itemId: "abc", transcodeRunTicks: 123)
        #expect(OfflineIndex.parseTaskName(name)?.itemId == "abc")
        #expect(OfflineIndex.transcodeRunTicks(name) == 123)
        #expect(OfflineIndex.transcodeRunTicks(OfflineIndex.taskName(owner: "u1", itemId: "abc")) == nil)
        #expect(OfflineIndex.parseTaskName("u1/abc/x") == nil)
    }

    // MARK: WebVTT

    @Test func webVTTReadsTheServersSubtitles() {
        let vtt = WebVTT("""
        WEBVTT

        1
        00:00:01.000 --> 00:00:02.500 position:50%
        <i>Hello</i> &amp; welcome

        00:01:00.000 --> 00:01:01.000
        Two
        lines

        broken --> nonsense
        x
        """)
        #expect(vtt.cues.count == 2)
        #expect(vtt.text(at: 1.5) == "Hello & welcome")
        #expect(vtt.text(at: 2.5) == nil)
        #expect(vtt.text(at: 60.5) == "Two\nlines")
        #expect(WebVTT.seconds("01:02:03.250") == 3723.25)
    }
}
