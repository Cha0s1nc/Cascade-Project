import Testing
import Foundation
@testable import CascadeKit

struct PlaylistBulkEditTests {
    private func row(_ id: String, entry: String? = nil) -> JfItem {
        var item = JfItem(id: id)
        item.playlistItemId = entry
        return item
    }
    private func ids(_ items: [JfItem]) -> [String] { items.map(\.id) }

    // test/playlist-edit.test.ts, ported.
    @Test func removeDropsTheSelectedRowsAndKeepsOrder() {
        let items = ["a", "b", "c", "d"].map { row($0) }
        #expect(ids(PlaylistEdit.removing(items, selected: ["b", "d"])) == ["a", "c"])
        #expect(ids(PlaylistEdit.removing(items, selected: [])) == ["a", "b", "c", "d"])
    }

    @Test func aDuplicateTrackRemovesOnlyTheSelectedEntry() {
        let items = [row("track", entry: "e1"), row("track", entry: "e2")]
        #expect(PlaylistEdit.removing(items, selected: ["e1"]).map(\.entryId) == ["e2"])
    }

    @Test func moveToTopKeepsRelativeOrderOnBothSides() {
        let items = ["a", "b", "c", "d"].map { row($0) }
        #expect(ids(PlaylistEdit.movingToTop(items, selected: ["c", "a"])) == ["a", "c", "b", "d"])
    }

    @Test func moveToBottomKeepsRelativeOrderOnBothSides() {
        let items = ["a", "b", "c", "d"].map { row($0) }
        #expect(ids(PlaylistEdit.movingToBottom(items, selected: ["a", "c"])) == ["b", "d", "a", "c"])
    }

    @Test func selectingNothingOrEverythingChangesNoOrder() {
        let items = ["a", "b", "c"].map { row($0) }
        #expect(ids(PlaylistEdit.movingToTop(items, selected: [])) == ["a", "b", "c"])
        #expect(ids(PlaylistEdit.movingToTop(items, selected: ["a", "b", "c"])) == ["a", "b", "c"])
    }

    @Test func theBulkSaveSendsOnlyIdsAndRenameStillSendsOnlyTheName() throws {
        let ids = String(decoding: try JSON.encoder.encode(PlaylistUpdate(ids: ["1", "2"])), as: UTF8.self)
        #expect(ids == #"{"Ids":["1","2"]}"#)
        let props = try #require(try JSONSerialization.jsonObject(
            with: try JSON.encoder.encode(PlaylistUpdate(name: "N", isPublic: true))) as? [String: Any])
        #expect(props["Name"] as? String == "N")
        #expect(props["IsPublic"] as? Bool == true)
        #expect(props["Ids"] == nil, "a rename must never carry Ids, which would replace the contents")
    }
}

struct MediaInfoTests {
    private func detail(_ json: String) throws -> MediaDetail {
        try JSON.decoder.decode(MediaDetail.self, from: Data(json.utf8))
    }

    @Test func aTrackShowsAllFourteenRowsFromTheMediaSource() throws {
        let d = try detail("""
        {"Name":"First Light Track 1","AlbumArtist":"Mika Sato","Artists":["Mika Sato"],"Album":"First Light",
         "ProductionYear":2012,"IndexNumber":1,"RunTimeTicks":2450000000,"Container":"flac",
         "DateCreated":"2026-10-01T10:00:00.0000000Z","UserData":{"PlayCount":3},
         "MediaSources":[{"Container":"flac","Size":5242880,"Bitrate":900000,
           "MediaStreams":[{"Type":"Audio","Codec":"flac","BitRate":900000,"SampleRate":44100,"Channels":2}]}]}
        """)
        let rows = MediaInfo.rows(d, addedFormat: { _ in "Oct 1, 2026" })
        #expect(rows.map(\.label) == ["Title", "Artist", "Album", "Year", "Track", "Duration", "Bitrate", "Codec",
                                      "Container", "Sample rate", "Channels", "Size", "Added", "Played"])
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["Duration"] == "4:05")
        #expect(byLabel["Bitrate"] == "900 kbps")
        #expect(byLabel["Codec"] == "FLAC")
        #expect(byLabel["Container"] == "FLAC")
        #expect(byLabel["Sample rate"] == "44100 Hz")
        #expect(byLabel["Channels"] == "2")
        #expect(byLabel["Size"] == "5.0 MB", "size lives on the media source in 10.11")
        #expect(byLabel["Added"] == "Oct 1, 2026")
        #expect(byLabel["Played"] == "3\u{00D7}")
    }

    @Test func missingValuesShowDashesOrLeaveTheRowOut() throws {
        let rows = MediaInfo.rows(try detail(#"{"Name":"Bare"}"#))
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["Title"] == "Bare")
        #expect(byLabel["Bitrate"] == "-")
        #expect(byLabel["Played"] == "Never")
        #expect(byLabel["Album"] == nil && byLabel["Year"] == nil && byLabel["Channels"] == nil)
    }

    @Test func aVideosFirstStreamIsNotUsedForTheAudioRows() throws {
        let d = try detail("""
        {"Name":"Film","MediaSources":[{"MediaStreams":[{"Type":"Video","Codec":"h264","BitRate":5000000},
          {"Type":"Audio","Codec":"ac3","BitRate":384000,"SampleRate":48000,"Channels":6}]}]}
        """)
        let byLabel = Dictionary(uniqueKeysWithValues: MediaInfo.rows(d).map { ($0.label, $0.value) })
        #expect(byLabel["Codec"] == "AC3")
        #expect(byLabel["Bitrate"] == "384 kbps")
    }
}

struct StreamURLTests {
    private let config = ServerConfig(url: "http://server", token: "tok", userId: "u1", deviceId: "d1")

    @Test func aSongCopiesTheAudioUniversalUrl() throws {
        let url = try #require(copyableStreamURL(config: config, item: JfItem(id: "s1", type: "Audio")))
        #expect(url.absoluteString.hasPrefix("http://server/Audio/s1/universal?"))
    }

    @Test func aMovieOrEpisodeCopiesTheVideoUrlTheDesktopNeverBuilt() throws {
        for type in ["Movie", "Episode"] {
            let url = try #require(copyableStreamURL(config: config, item: JfItem(id: "v1", type: type)))
            #expect(url.absoluteString == "http://server/Videos/v1/stream?static=true&ApiKey=tok")
        }
        var byMediaType = JfItem(id: "v2", type: "Video")
        byMediaType.mediaType = "Video"
        #expect(copyableStreamURL(config: config, item: byMediaType)?.path == "/Videos/v2/stream")
    }
}

struct MetadataEditTests {
    private let item: [String: Any] = [
        "Id": "x", "Name": "Old", "Album": "A", "AlbumArtist": "AA", "Artists": ["P", "Q"], "Genres": ["Rock"],
        "ProductionYear": 2001, "IndexNumber": 3, "ParentIndexNumber": 1,
        "ProviderIds": ["MusicBrainzTrack": "abc"], "LockedFields": ["Name"], "RunTimeTicks": 300000000,
    ]

    @Test func theFormStartsFromTheFetchedItem() {
        let f = MetadataEdit.fields(from: item)
        #expect(f.name == "Old" && f.album == "A" && f.albumArtist == "AA")
        #expect(f.artists == "P, Q" && f.genres == "Rock")
        #expect(f.year == "2001" && f.track == "3" && f.disc == "1")
    }

    @Test func applyKeepsEveryFieldTheFormDoesNotShow() throws {
        var f = MetadataEdit.fields(from: item)
        f.name = "  New  "
        f.artists = "One, Two ,, "
        f.genres = ""
        let out = try MetadataEdit.apply(f, to: item)
        #expect(out["Name"] as? String == "New")
        #expect(out["Artists"] as? [String] == ["One", "Two"])
        #expect(out["Genres"] as? [String] == [])
        // A partial body would blank these on the server.
        #expect(out["Id"] as? String == "x")
        #expect(out["RunTimeTicks"] as? Int == 300000000)
        #expect((out["ProviderIds"] as? [String: String]) == ["MusicBrainzTrack": "abc"])
        #expect(out["LockedFields"] as? [String] == ["Name"])
    }

    @Test func anEmptyNameKeepsTheOldOneAndEmptyNumbersClear() throws {
        var f = MetadataEdit.fields(from: item)
        f.name = "   "
        f.year = ""; f.track = " "; f.disc = ""
        let out = try MetadataEdit.apply(f, to: item)
        #expect(out["Name"] as? String == "Old")
        #expect(out["ProductionYear"] is NSNull && out["IndexNumber"] is NSNull && out["ParentIndexNumber"] is NSNull)
    }

    @Test func aNumberFieldThatIsNotANumberThrowsInsteadOfClearing() {
        var f = MetadataEdit.fields(from: item)
        f.year = "19x5"
        #expect(throws: MetadataEdit.NotANumber.self) { try MetadataEdit.apply(f, to: item) }
    }

    @Test func theListIsTrimmedAndDropsEmpties() {
        #expect(MetadataEdit.list(" a, b ,,c,  ") == ["a", "b", "c"])
        #expect(MetadataEdit.list("").isEmpty)
    }

    @Test func theEditedItemSurvivesJsonRoundTripWithItsKeysIntact() throws {
        let out = try MetadataEdit.apply(MetadataEdit.fields(from: item), to: item)
        let data = try JSONSerialization.data(withJSONObject: out)
        let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(back["ProviderIds"] as? [String: String] == ["MusicBrainzTrack": "abc"])
        #expect(back["ProductionYear"] as? Int == 2001)
    }
}
