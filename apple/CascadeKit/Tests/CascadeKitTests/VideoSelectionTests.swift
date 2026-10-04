import Foundation
import Testing
@testable import CascadeKit

// neededAudioStreamIndex and withoutAudioCodecs from test/playback.test.ts,
// plus the HLS offset rule and the pure parts of the player's keys.
struct VideoSelectionTests {
    private let decodable = ["aac", "mp3", "opus", "flac", "vorbis"]

    private func audio(_ index: Int, _ codec: String, isDefault: Bool = false) -> JfMediaStream {
        JfMediaStream(type: "Audio", index: index, codec: codec, isDefault: isDefault)
    }

    @Test func aSingleAudioTrackNeverNeedsForcing() {
        #expect(neededAudioStreamIndex([audio(1, "truehd", isDefault: true)], decodable: decodable) == nil)
        #expect(neededAudioStreamIndex([audio(1, "aac", isDefault: true)], decodable: decodable) == nil)
    }

    @Test func aDecodableDefaultNeedsNothing() {
        #expect(neededAudioStreamIndex([audio(1, "aac", isDefault: true), audio(2, "ac3")], decodable: decodable) == nil)
    }

    @Test func anUndecodableDefaultForcesTheFirstTrackThatIsDecodable() {
        let streams = [audio(1, "truehd", isDefault: true), audio(2, "ac3"), audio(3, "aac")]
        #expect(neededAudioStreamIndex(streams, decodable: decodable) == 3)
    }

    @Test func noDefaultFlagFallsBackToTheFirstAudioStream() {
        #expect(neededAudioStreamIndex([audio(1, "dts"), audio(2, "aac")], decodable: decodable) == 2)
    }

    @Test func nothingDecodableLeavesItToTheServer() {
        #expect(neededAudioStreamIndex([audio(1, "truehd", isDefault: true), audio(2, "dts")], decodable: decodable) == nil)
    }

    @Test func videoAndSubtitleStreamsAreIgnored() {
        let streams = [JfMediaStream(type: "Video", index: 0, codec: "hevc"), audio(1, "truehd", isDefault: true),
                       audio(2, "aac"), JfMediaStream(type: "Subtitle", index: 3, codec: "subrip")]
        #expect(neededAudioStreamIndex(streams, decodable: decodable) == 2)
        #expect(neededAudioStreamIndex(nil, decodable: decodable) == nil)
    }

    @Test func theVideoProfileClaimsAnAudioListToCheckAgainst() {
        #expect(DeviceProfile.appleVideo.videoDirectPlayAudioCodecs == ["aac", "ac3", "eac3", "mp3"])
    }

    @Test func withoutAudioCodecsDropsACodecFromVideoDirectPlayOnly() {
        let profile = DeviceProfile(directPlayProfiles: [
            DirectPlayProfile(type: .video, container: "mkv", audioCodec: "aac,mp3,ac3,eac3"),
            DirectPlayProfile(type: .video, container: "mp4", audioCodec: "aac,ac3"),
            DirectPlayProfile(type: .audio, container: "flac", audioCodec: "flac,ac3"),
        ], transcodingProfiles: [])
        let out = profile.withoutAudioCodecs(["ac3"])
        #expect(out.directPlayProfiles[0].audioCodec == "aac,mp3,eac3")
        #expect(out.directPlayProfiles[1].audioCodec == "aac")
        #expect(out.directPlayProfiles[2].audioCodec == "flac,ac3")
    }

    @Test func withoutAudioCodecsIsCaseInsensitiveAndChangesNothingWhenNothingIsDropped() {
        let profile = DeviceProfile(directPlayProfiles: [
            DirectPlayProfile(type: .video, container: "mp4", audioCodec: "AAC"),
        ], transcodingProfiles: [])
        #expect(profile.withoutAudioCodecs(["aac"]).directPlayProfiles[0].audioCodec == "")
        #expect(profile.withoutAudioCodecs(["ac3"]).directPlayProfiles[0].audioCodec == "AAC")
        #expect(profile.withoutAudioCodecs([]).directPlayProfiles[0].audioCodec == "AAC")
    }

    @Test func hlsUrlsAreRecognisedWithOrWithoutAQuery() {
        #expect(isHlsUrl("http://x/videos/1/master.m3u8?a=b"))
        #expect(isHlsUrl("http://x/videos/1/main.M3U8"))
        #expect(!isHlsUrl("http://x/videos/1/stream.mp4?static=true"))
        #expect(!isHlsUrl("http://x/videos/1/stream?name=a.m3u8.mp4"))
    }

    // MARK: keys

    @Test func skipsStayInsideTheItem() {
        #expect(VideoControls.skipTarget(from: 3, by: -10, duration: 100) == 0)
        #expect(VideoControls.skipTarget(from: 95, by: 10, duration: 100) == 100)
        #expect(VideoControls.skipTarget(from: 50, by: 5, duration: 100) == 55)
        #expect(VideoControls.skipTarget(from: 50, by: 5, duration: 0) == 55)
    }

    @Test func digitKeysJumpToTenths() {
        #expect(VideoControls.tenthTarget(0, duration: 200) == 0)
        #expect(VideoControls.tenthTarget(5, duration: 200) == 100)
        #expect(VideoControls.tenthTarget(9, duration: 200) == 180)
        #expect(VideoControls.tenthTarget(5, duration: 0) == nil)
        #expect(VideoControls.tenthTarget(10, duration: 200) == nil)
    }

    @Test func speedStopsAtTheEndsAndStepsFromNormalWhenOffTheList() {
        #expect(VideoControls.nextRate(from: 1, faster: true) == 1.25)
        #expect(VideoControls.nextRate(from: 1, faster: false) == 0.75)
        #expect(VideoControls.nextRate(from: 2, faster: true) == 2)
        #expect(VideoControls.nextRate(from: 0.25, faster: false) == 0.25)
        #expect(VideoControls.nextRate(from: 1.1, faster: true) == 1.25)
        #expect(VideoControls.rateLabel(1) == "1x")
        #expect(VideoControls.rateLabel(0.75) == "0.75x")
    }

    @Test func aFrameIsTheFilmsRateOr24() {
        #expect(abs(VideoControls.frameDuration(fps: 25) - 0.04) < 1e-9)
        #expect(abs(VideoControls.frameDuration(fps: nil) - 1.0 / 24) < 1e-9)
        #expect(abs(VideoControls.frameDuration(fps: 0) - 1.0 / 24) < 1e-9)
    }

    @Test func clockReadsLikeAPlayers() {
        #expect(VideoControls.clock(309) == "5:09")
        #expect(VideoControls.clock(3909) == "1:05:09")
        #expect(VideoControls.clock(-4) == "0:00")
        #expect(VideoControls.clock(.nan) == "0:00")
    }

    // MARK: subtitles

    @Test func subtitlesListDefaultFirstThenForcedThenTheRestInOrder() {
        let found = [
            SubtitleChoice(id: 0, label: "French"),
            SubtitleChoice(id: 1, label: "English (forced)", isForced: true),
            SubtitleChoice(id: 2, label: "English", isDefault: true),
            SubtitleChoice(id: 3, label: "German"),
        ]
        #expect(orderedSubtitles(found).map(\.id) == [2, 1, 0, 3])
    }

    @Test func cTurnsSubtitlesOffAndBackOnToYourPick() {
        // Showing track 2: off, remembering 2.
        var r = toggledSubtitle(showing: 2, remembered: 0, count: 4)
        #expect(r?.selection == nil && r?.remembered == 2)
        // Off: back to 2, not the default.
        r = toggledSubtitle(showing: nil, remembered: 2, count: 4)
        #expect(r?.selection == 2)
        // A remembered track the new item does not have is clamped.
        r = toggledSubtitle(showing: nil, remembered: 5, count: 2)
        #expect(r?.selection == 1)
        #expect(toggledSubtitle(showing: nil, remembered: 0, count: 0) == nil)
    }
}
