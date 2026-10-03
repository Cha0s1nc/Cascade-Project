import Foundation
import Testing
@testable import CascadeKit

struct VideoTests {
    @Test func episodeCodesReadLikeTheDesktops() {
        var e = JfItem(id: "e", name: "Pilot", type: "Episode")
        e.indexNumber = 2
        e.parentIndexNumber = 1
        #expect(VideoPlayback.episodeCode(e) == "S1:E2")
        e.parentIndexNumber = nil
        #expect(VideoPlayback.episodeCode(e) == "E2")
        #expect(VideoPlayback.episodeCode(JfItem(id: "m", name: "Movie", type: "Movie")) == nil)
    }

    /// The server trusts every claim, so the profile is pinned: MP4 direct
    /// play, HLS for the rest, text subtitles in the manifest, pictures burned.
    @Test func theVideoProfileSaysWhatAVPlayerCanDo() throws {
        let json = try #require(String(data: JSON.encoder.encode(DeviceProfile.appleVideo), encoding: .utf8))
        #expect(json.contains(#""Protocol":"hls""#))
        #expect(json.contains(#""Container":"mp4,m4v,mov""#))
        let subs = DeviceProfile.appleVideo.subtitleProfiles
        #expect(subs.first { $0.format == "subrip" }?.method == "Hls")
        #expect(subs.first { $0.format == "pgssub" }?.method == "Encode")
        #expect(!json.contains("mkv"))
    }

    @Test func onlyAudioStreamsWithAnIndexArePickable() {
        var item = JfItem(id: "m", type: "Movie")
        item.mediaStreams = [
            JfMediaStream(type: "Video", index: 0),
            JfMediaStream(type: "Audio", index: 1, language: "eng"),
            JfMediaStream(type: "Audio", index: nil),
            JfMediaStream(type: "Audio", index: 2, language: "spa"),
        ]
        #expect(VideoPlayback.audioTracks(item).map(\.index) == [1, 2])
    }
}

struct MediaTrackLabelTests {
    @Test func theServersNameWithoutTheCodec() {
        #expect(mediaTrackLabel(playlistName: "English - Default - SUBRIP", fallback: "English") == "English - Default")
        #expect(mediaTrackLabel(playlistName: "For ENG Dub - English - SUBRIP", fallback: "English") == "For ENG Dub - English")
        #expect(mediaTrackLabel(playlistName: "English Signs - ASS", fallback: "English") == "English Signs")
        #expect(mediaTrackLabel(playlistName: "English cc - Hearing Impaired - ASS", fallback: "English") == "English cc - Hearing Impaired")
        #expect(mediaTrackLabel(playlistName: "Thai - SUBRIP", fallback: "Thai") == "Thai")
    }

    @Test func noNameIsTheSystemsName() {
        #expect(mediaTrackLabel(playlistName: nil, fallback: "English") == "English")
        #expect(mediaTrackLabel(playlistName: "  ", fallback: "English") == "English")
        #expect(mediaTrackLabel(playlistName: "SDH", fallback: "English") == "SDH", "a lone uppercase name is a name, not a codec")
    }
}

struct VideoResumeTests {
    @Test func theTranscodeURLLosesItsStartSoTheStreamIsTheWholeFilm() {
        let url = VideoPlayback.withoutStartTicks("https://s/videos/1/master.m3u8?MediaSourceId=a&StartTimeTicks=42000000000&api_key=k")
        #expect(url?.absoluteString == "https://s/videos/1/master.m3u8?MediaSourceId=a&api_key=k")
        #expect(VideoPlayback.withoutStartTicks("https://s/videos/1/master.m3u8?api_key=k")?.absoluteString == "https://s/videos/1/master.m3u8?api_key=k")
    }
}

struct VideoSearchTests {
    @Test func searchesMoviesShowsAndEpisodesAcrossLibraries() throws {
        let params = try #require(VideoPlayback.searchParams(term: "  infinity castle ", userId: "u1"))
        #expect(params["searchTerm"] == "infinity castle")
        #expect(params["includeItemTypes"] == "Movie,Series,Episode")
        #expect(params["recursive"] == "true")
        #expect(params["userId"] == "u1")
        #expect(params["fields"]??.contains("MediaStreams") == true, "results play like list items")
        #expect(VideoPlayback.searchParams(term: "   ", userId: "u1") == nil)
    }
}
