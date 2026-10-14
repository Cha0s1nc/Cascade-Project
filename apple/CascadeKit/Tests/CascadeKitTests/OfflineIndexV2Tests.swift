import Foundation
import Testing
@testable import CascadeKit

// Catalog version 2: what it adds to version 1 (docs/offline-mode-plan.md,
// section 1). The desktop's test/offline-index-v2.test.ts covers the same.
struct OfflineIndexV2Tests {
    /// A version 1 index.json as OfflineLibrary wrote it: JSONEncoder's own
    /// key case, dates as seconds since 2001, no version, libraries or user.
    static let version1 = Data("""
    {
      "tracks": {
        "a1b2c3d4e5f60718293a4b5c6d7e8f90": {
          "item": {"id": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "name": "Intro", "type": "Audio", "mediaType": "Audio",
                   "album": "First Light", "albumId": "0aa1bb2cc3dd4ee5ff60718293a4b5c6", "albumArtist": "The Lanterns",
                   "artists": ["The Lanterns"], "albumPrimaryImageTag": "f0e1d2c3b4a5", "runTimeTicks": 1835000000,
                   "indexNumber": 1, "parentIndexNumber": 1, "productionYear": 2019, "normalizationGain": -6.2,
                   "dateCreated": "2026-01-10T00:00:00.0000000Z", "imageTags": {"primary": "f0e1d2c3b4a5"}},
          "file": "media/a1b2c3d4e5f60718293a4b5c6d7e8f90.flac",
          "bytes": 21456789
        },
        "b2c3d4e5f60718293a4b5c6d7e8f90a1": {
          "item": {"id": "b2c3d4e5f60718293a4b5c6d7e8f90a1", "name": "Harbor", "type": "Audio",
                   "albumId": "0aa1bb2cc3dd4ee5ff60718293a4b5c6", "indexNumber": 2},
          "bytes": 0
        }
      },
      "collections": [
        {"item": {"id": "0aa1bb2cc3dd4ee5ff60718293a4b5c6", "name": "First Light", "type": "MusicAlbum", "childCount": 2},
         "trackIds": ["a1b2c3d4e5f60718293a4b5c6d7e8f90", "b2c3d4e5f60718293a4b5c6d7e8f90a1"]}
      ],
      "plays": [{"itemId": "a1b2c3d4e5f60718293a4b5c6d7e8f90", "userId": "5f6e7d8c-9b0a-4c1d-8e2f-3a4b5c6d7e8f", "date": 781000000}],
      "albumGains": {"0aa1bb2cc3dd4ee5ff60718293a4b5c6": -3.5}
    }
    """.utf8)
    static let track1 = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    static let track2 = "b2c3d4e5f60718293a4b5c6d7e8f90a1"
    static let album = "0aa1bb2cc3dd4ee5ff60718293a4b5c6"

    static let views: [JfItem] = [
        JfItem(id: "libmusic", name: "Music", collectionType: "music"),
        JfItem(id: "libmovies", name: "Films", collectionType: "movies"),
        JfItem(id: "libbooks", name: "Books", collectionType: "books"),
        JfItem(id: "../x", name: "Bad", collectionType: "music"),
    ]

    func episode(_ id: String, season: String) -> JfItem {
        var e = JfItem(id: id, name: id, type: "Episode")
        e.seasonId = season
        e.seriesId = "show"
        return e
    }

    @Test func aRealVersion1FileReadsIntoVersion2WithNothingLost() throws {
        let index = OfflineIndex.decode(Self.version1)
        #expect(index.version == 2)
        #expect(Set(index.tracks.keys) == [Self.track1, Self.track2])
        #expect(index.readyFile(Self.track1) == "media/\(Self.track1).flac")
        #expect(index.tracks[Self.track1]?.bytes == 21456789)
        #expect(index.tracks[Self.track1]?.item.normalizationGain == -6.2)
        #expect(index.collection(Self.album)?.trackIds == [Self.track1, Self.track2])
        #expect(index.plays.count == 1)
        #expect(index.albumGains == [Self.album: -3.5])
        #expect(index.libraries.isEmpty && index.user == nil && index.history == nil)
        // Saved and read again, it is the same index.
        #expect(OfflineIndex.decode(index.encoded()) == index)
        let again = OfflineIndex.decode(index.encoded())
        #expect(again.tracks[Self.track1]?.item.dateCreated == "2026-01-10T00:00:00.0000000Z")
    }

    @Test func version1ItemsFallIntoThePlaceholderUntilPlaced() {
        var index = OfflineIndex.decode(Self.version1)
        let music = OfflineIndex.placeholderLibraries["Audio"]!
        #expect(index.library(of: Self.track1) == music.id)
        #expect(index.librariesInUse == [music])
        #expect(index.unplacedTrackIds == [Self.track1, Self.track2])

        index.setLibraries(Self.views)
        #expect(index.libraries.map(\.id) == ["libmusic", "libmovies"])
        index.assignLibrary([Self.track1], to: "libmusic")
        index.assignLibrary([Self.track2], to: "nowhere")
        #expect(index.library(of: Self.track1) == "libmusic")
        #expect(index.library(of: Self.track2) == music.id)
        #expect(index.librariesInUse.map(\.id) == ["libmusic", music.id])
        #expect(index.unplacedTrackIds == [Self.track2])

        index.setLibraries(Self.views.filter { $0.id != "libmusic" })
        #expect(index.library(of: Self.track1) == music.id)
    }

    @Test func eachKindHasItsOwnPlaceholder() {
        var index = OfflineIndex()
        index.add(JfItem(id: "m1", type: "Movie"), tracks: [JfItem(id: "m1", type: "Movie")])
        index.add(JfItem(id: "s1", type: "Season"), tracks: [episode("e1", season: "s1")])
        #expect(index.library(of: "m1") == OfflineIndex.placeholderLibraries["Movie"]!.id)
        #expect(index.library(of: "e1") == OfflineIndex.placeholderLibraries["Episode"]!.id)
        #expect(index.library(of: "nope") == nil)
    }

    @Test func aPlaceholderIdStoredOnATrackIsNotTrusted() throws {
        var index = OfflineIndex.decode(Self.version1)
        index.tracks[Self.track1]?.library = "cascade-offline-movies"
        #expect(OfflineIndex.decode(index.encoded()).tracks[Self.track1]?.library == nil)
    }

    @Test func aSeasonKeepsItsShowUntilTheLastEpisodeGoes() {
        var index = OfflineIndex()
        let show = JfItem(id: "show", name: "Show", type: "Series")
        let s1 = JfItem(id: "s1", name: "Season 1", type: "Season")
        let s2 = JfItem(id: "s2", name: "Season 2", type: "Season")
        index.add(s1, tracks: [episode("e1", season: "s1"), episode("e2", season: "s1")], containers: [show, s1, JfItem(id: "x", type: "Folder")])
        index.add(s2, tracks: [episode("e3", season: "s2")], containers: [show, s2])
        #expect(Set(index.containers.keys) == ["s1", "s2", "show"])
        index.remove("s1")
        #expect(Set(index.containers.keys) == ["s2", "show"])
        index.remove("s2")
        #expect(index.containers.isEmpty)
    }

    @Test func onlyMediaIsKeptAndAudioKeepsNoStreams() {
        var index = OfflineIndex()
        var song = JfItem(id: "t1", type: "Audio")
        var stream = JfMediaStream()
        stream.type = "Audio"
        song.mediaStreams = [stream]
        song.mediaSources = [JfMediaSourceRef(id: "a", bitrate: 900), JfMediaSourceRef(id: "b")]
        index.add(JfItem(id: "p", type: "Playlist"), tracks: [song, JfItem(id: "v", type: "Video"), JfItem(id: "../x", type: "Audio")])
        #expect(index.collection("p")?.trackIds == ["t1"])
        #expect(index.tracks["t1"]?.item.mediaStreams == nil)
        #expect(index.tracks["t1"]?.item.mediaSources?.map(\.id) == ["a"])
    }

    @Test func subtitlesAreFiles() {
        var index = OfflineIndex()
        index.add(JfItem(id: "m1", type: "Movie"), tracks: [JfItem(id: "m1", type: "Movie")])
        index.markReady("m1", file: "media/m1.mp4", bytes: 100)
        index.setSubtitles("m1", [
            .init(index: 3, file: "subs/m1.3.vtt", language: "eng"),
            .init(index: 4, file: "subs/m1.4.vtt"),
            .init(index: 4, file: "subs/m1.4.vtt"),
            .init(index: 5, file: "subs/../../x.vtt"),
            .init(index: -1, file: "subs/m1.1.vtt"),
        ])
        #expect(index.tracks["m1"]?.subs?.map(\.index) == [3, 4])
        #expect(index.files == ["media/m1.mp4", "subs/m1.3.vtt", "subs/m1.4.vtt"])
        #expect(index.reconcile(filesOnDisk: ["media/m1.mp4", "subs/m1.3.vtt", "subs/old.2.vtt"]) == ["subs/old.2.vtt"])
        #expect(index.tracks["m1"]?.subs?.map(\.index) == [3])
        #expect(index.remove("m1") == ["media/m1.mp4", "subs/m1.3.vtt"])
    }

    @Test func onlyPlainSubtitlePathsAreSafe() {
        #expect(OfflineIndex.isSafeSubtitlePath("subs/abc123.12.vtt"))
        for bad in ["subs/abc.vtt", "subs/a/b.1.vtt", "media/a.1.vtt", "subs/a.1.srt", "../subs/a.1.vtt", "subs/a.12345.vtt"] {
            #expect(!OfflineIndex.isSafeSubtitlePath(bad), "\(bad)")
        }
    }

    @Test func spicyLyricsExpireAfter25Days() {
        var index = OfflineIndex()
        index.add(JfItem(id: "a", type: "MusicAlbum"), tracks: [JfItem(id: "t1", type: "Audio"), JfItem(id: "t2", type: "Audio")])
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let lines = [LyricLine(start: 0, text: "la", words: nil)]
        index.setLyrics("t1", source: "spicy", synced: true, lines: lines, now: saved)
        index.setLyrics("t2", source: "lrclib", synced: true, lines: lines, now: saved)
        let day = 86_400.0
        #expect(index.lyrics(of: "t1", now: saved.addingTimeInterval(24 * day)) != nil)
        #expect(index.lyrics(of: "t1", now: saved.addingTimeInterval(25 * day)) == nil)
        #expect(index.lyrics(of: "t2", now: saved.addingTimeInterval(3650 * day)) != nil)
        #expect(index.expiredLyricsTrackIds(now: saved.addingTimeInterval(25 * day)) == ["t1"])
        index.dropLyrics("t1")
        #expect(index.expiredLyricsTrackIds(now: saved.addingTimeInterval(25 * day)).isEmpty)

        // Stored lyrics survive a save.
        #expect(OfflineIndex.decode(index.encoded()).tracks["t2"]?.lyrics?.lines == lines)
    }

    @Test func spicyLyricsWithNoExpiryAreTreatedAsExpired() {
        var index = OfflineIndex()
        index.add(JfItem(id: "a", type: "MusicAlbum"), tracks: [JfItem(id: "t1", type: "Audio")])
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        index.tracks["t1"]?.lyrics = .init(source: "spicy", synced: true, lines: [LyricLine(start: 0, text: "x", words: nil)],
                                            savedAt: saved, expiresAt: nil)
        #expect(OfflineIndex.decode(index.encoded()).lyrics(of: "t1", now: saved.addingTimeInterval(1)) == nil)
    }

    @Test func segmentsExplicitUserAndHistorySurviveASave() {
        var index = OfflineIndex()
        index.add(JfItem(id: "m1", type: "Movie"), tracks: [JfItem(id: "m1", type: "Movie")])
        index.setSegments("m1", [.init(type: "Intro", startTicks: 0, endTicks: 900), .init(type: "Outro", startTicks: 50, endTicks: 10)])
        index.setExplicit("m1", true)
        index.setUser(.init(id: "u-1", name: "Kai", policy: .init(enableContentDownloading: true)))
        let played = JfItem(id: "m1", userData: JfUserData(playCount: 2))
        index.setHistory([played, JfItem(id: "../bad"), JfItem(id: "t9")], takenAt: Date(timeIntervalSince1970: 1_790_000_000))

        let back = OfflineIndex.decode(index.encoded())
        #expect(back.tracks["m1"]?.segments == [.init(type: "Intro", startTicks: 0, endTicks: 900)])
        #expect(back.tracks["m1"]?.explicit == true)
        #expect(back.user?.policy.enableContentDownloading == true)
        #expect(back.history?.entries.map(\.id) == ["m1", "t9"])
        #expect(back.history?.entries.first?.playCount == 2)

        index.setUser(.init(id: "../u", name: "x", policy: .init()))
        #expect(index.user == nil)
    }

    @Test func theHistorySnapshotIsCapped() {
        let items = (0..<(OfflineIndex.maxHistoryEntries + 20)).map { JfItem(id: "t\($0)") }
        #expect(OfflineIndex.historyEntries(of: items).count == OfflineIndex.maxHistoryEntries)
    }
}
