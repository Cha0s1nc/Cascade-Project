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
