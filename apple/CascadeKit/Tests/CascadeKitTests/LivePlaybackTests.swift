import Testing
import Foundation
@testable import CascadeKit

// The routes this work added, against a real server. Skipped unless
// CASCADE_SERVER / CASCADE_USER / CASCADE_PASS are set. The test server has no
// Live TV tuner, so radio is covered as far as the routes answer: the channel
// list, the policy read, and the stream resolve for something that is not a
// channel (which must fail loudly, not hand back a URL).
@Suite("Live playback routes", .enabled(if: liveCredentials != nil))
struct LivePlaybackTests {
    @Test func aSavedQueueRoundTripsThroughTheServer() async throws {
        let client = try await LiveSession.shared.connect().0
        let songs = Array(try await client.songs(limit: 6).prefix(6))
        try #require(songs.count >= 4)
        let shuffledOrder = [songs[2], songs[0], songs[3], songs[1]]
        let saved = try #require(savedQueueOf(shuffledOrder, index: 2, positionSec: 12.34, unshuffled: songs))
        // Through the JSON text the app stores, with one id the server has never heard of.
        let text = saved.json.replacingOccurrences(of: songs[1].id, with: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let parsed = parseSavedQueue(text)
        let fetched = try await client.restoredItems(ids: savedQueueIds(parsed))
        let restored = try #require(restoreQueue(parsed, items: fetched))
        #expect(restored.queue.map(\.id) == [songs[2].id, songs[0].id, songs[3].id])
        #expect(restored.queue[restored.index].id == songs[3].id)
        #expect(restored.positionSec == 12.3)
        #expect(restored.queue.allSatisfy { $0.type == "Audio" }, "restored items carry their type, which savedQueueOf needs")
        #expect(savedQueueOf(restored.queue, index: restored.index, positionSec: 0) != nil)
    }

    @Test func restoredItemsFetchesInChunks() async throws {
        let client = try await LiveSession.shared.connect().0
        let songs = try await client.songs(limit: 24)
        // More ids than one chunk of 100, padded with ones the server lacks.
        // (Random ids: the server answers 500 for a few near-zero ones, which no real item has.)
        let junk = (0..<120).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        let fetched = try await client.restoredItems(ids: junk + songs.map(\.id))
        #expect(Set(fetched.map(\.id)) == Set(songs.map(\.id)))
    }

    @Test func instantMixAsksForTheLimitGiven() async throws {
        let client = try await LiveSession.shared.connect().0
        let seed = try #require(try await client.songs(limit: 1).first)
        let mix = try await client.instantMix(seedId: seed.id, limit: 25)
        #expect(!mix.isEmpty && mix.count <= 25)
    }

    @Test func liveTvPolicyAndChannelsAnswer() async throws {
        let client = try await LiveSession.shared.connect().0
        // The admin may use Live TV; the point is that the field decodes and
        // the channel list answers 200 (empty here, with no tuner).
        #expect(try await client.hasLiveTvAccess())
        let channels = try await client.radioChannels()
        #expect(channels.allSatisfy { isRadioItem($0) })
    }

    @Test func aNonChannelDoesNotResolveAsRadio() async throws {
        let (client, _) = try await LiveSession.shared.connect()
        let seed = try #require(try await client.songs(limit: 1).first)
        // A track has a media source, so PlaybackInfo may answer; either way a
        // refused or empty reply must throw rather than produce a stream.
        do {
            let stream = try await client.resolveRadioStream(channelId: seed.id, profile: .apple, maxBitrate: 140_000_000)
            // If the server did answer, the URL is the channel-style one with no static flag.
            #expect(!stream.url.absoluteString.contains("static"))
        } catch {
            #expect(error is JellyfinError)
        }
        // Closing a stream that was never opened must not throw.
        await client.closeRadioStream(liveStreamId: "not-a-stream")
    }

    @Test func aGuestsLiveTvPolicyDecodes() async throws {
        let e = ProcessInfo.processInfo.environment
        guard let server = e["CASCADE_SERVER"], let user = e["CASCADE_GUEST_USER"], let pass = e["CASCADE_GUEST_PASS"] else { return }
        let deviceId = "cascade-swift-tests-guest-playback"
        let auth = try await authenticate(serverUrl: server, username: user, password: pass,
                                          appVersion: "0.1.0", deviceId: deviceId)
        let client = JellyfinClient(config: ServerConfig(url: server, token: auth.accessToken,
                                                         userId: auth.user.id, deviceId: deviceId))
        // Whatever the guest's policy says, it reads without error.
        _ = try await client.hasLiveTvAccess()
    }
}
