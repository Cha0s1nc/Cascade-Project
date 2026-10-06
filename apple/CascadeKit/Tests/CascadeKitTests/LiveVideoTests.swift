import Testing
import Foundation
@testable import CascadeKit

// Video stream selection and chapters against a real server. Skipped unless
// CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set. The test server's
// movies: an MP4 (direct play) and an MKV with two audio tracks (English
// default, Japanese second), neither with chapters or subtitles.
@Suite("Live video", .enabled(if: liveCredentials != nil))
struct LiveVideoTests {
    private func movie(named part: String) async throws -> (JellyfinClient, ServerConfig, JfItem) {
        let (client, config) = try await LiveSession.shared.connect()
        let item = try #require(try await client.movies().first { $0.name?.contains(part) == true })
        return (client, config, item)
    }

    @Test func anMp4PlaysDirectly() async throws {
        let (client, config, item) = try await movie(named: "Test Movie")
        let stream = try await VideoPlayback.resolve(client: client, config: config, item: item)
        #expect(stream.direct)
        #expect(stream.startTicks == 0)
    }

    @Test func anAudioTrackChoiceComesBackAsATranscodeCarryingThatTrack() async throws {
        let (client, config, item) = try await movie(named: "Second Feature")
        let tracks = VideoPlayback.audioTracks(item)
        #expect(tracks.count == 2)
        let japanese = try #require(tracks.first { $0.language == "jpn" }?.index)
        let stream = try await VideoPlayback.resolve(client: client, config: config, item: item, audioStreamIndex: japanese)
        #expect(!stream.direct)
        #expect(isHlsUrl(stream.url.absoluteString))
        #expect(stream.url.absoluteString.contains("AudioStreamIndex=\(japanese)"))
        #expect(stream.mediaSourceId != nil, "the server honors a track only beside its media source id")
    }

    /// The master playlist spans the whole item whatever the offset, so a
    /// resumed transcode must not also count the offset on the player's clock.
    @Test func aResumedHlsTranscodeCarriesNoOffset() async throws {
        let (client, config, item) = try await movie(named: "Second Feature")
        let stream = try await VideoPlayback.resolve(client: client, config: config, item: item, startTicks: 300_000_000)
        #expect(!stream.direct)
        #expect(stream.startTicks == 0)
        #expect(!stream.url.absoluteString.contains("StartTimeTicks"))
    }

    @Test func theMkvsDefaultTrackIsDecodableSoNothingIsForced() async throws {
        let (_, _, item) = try await movie(named: "Second Feature")
        #expect(neededAudioStreamIndex(item.mediaStreams, decodable: DeviceProfile.appleVideo.videoDirectPlayAudioCodecs) == nil)
    }

    @Test func chaptersAnswerAndMissingOnesAreEmpty() async throws {
        let (client, _, item) = try await movie(named: "Second Feature")
        #expect(await client.chapters(of: item).isEmpty, "the test media has none; the route must still answer 200 and decode")
        let ghost = JfItem(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), type: "Movie")
        #expect(await client.chapters(of: ghost).isEmpty)
    }
}
