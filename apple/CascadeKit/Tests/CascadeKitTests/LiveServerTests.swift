import Testing
import Foundation
import AVFoundation
@testable import CascadeKit

// These talk to a real Jellyfin. They are skipped unless the environment names
// a server, so `swift test` stays offline and fast by default:
//
//   CASCADE_SERVER=https://host CASCADE_USER=name CASCADE_PASS=pw swift test
//
// The point of these is the one thing unit tests cannot check: that the shapes
// this app sends are the shapes this server's version actually accepts. Never
// trust an endpoint's shape from memory.

private struct Env {
    let server: String, user: String, pass: String
    init?() {
        let e = ProcessInfo.processInfo.environment
        guard let s = e["CASCADE_SERVER"], let u = e["CASCADE_USER"], let p = e["CASCADE_PASS"] else { return nil }
        server = s; user = u; pass = p
    }
}

private let liveEnv = Env()
private let deviceId = "cascade-swift-test-\(ProcessInfo.processInfo.hostName)"

@Suite("Live server", .enabled(if: liveEnv != nil))
struct LiveServerTests {

    private func signIn() async throws -> (JellyfinClient, ServerConfig) {
        let env = liveEnv!
        let auth = try await authenticate(serverUrl: env.server, username: env.user,
                                          password: env.pass, appVersion: "0.1.0", deviceId: deviceId)
        let config = ServerConfig(url: env.server, token: auth.accessToken,
                                  userId: auth.user.id, deviceId: deviceId)
        return (JellyfinClient(config: config), config)
    }

    @Test func authenticateReturnsATokenAndUserId() async throws {
        let (_, config) = try await signIn()
        #expect(!config.token.isEmpty)
        #expect(!config.userId.isEmpty)
    }

    @Test func wrongPasswordFailsLoudly() async throws {
        let env = liveEnv!
        // Rule one: a write or a sign-in that fails must throw, not quietly
        // return something that looks like success.
        await #expect(throws: JellyfinError.self) {
            _ = try await authenticate(serverUrl: env.server, username: env.user,
                                       password: "definitely-not-the-password",
                                       appVersion: "0.1.0", deviceId: deviceId)
        }
    }

    @Test func playbackInfoDirectPlaysAFlacTrack() async throws {
        let (client, config) = try await signIn()

        let response: JfItemsResponse = try await client.get("/Items", params: [
            "userId": config.userId,
            "includeItemTypes": "Audio",
            "recursive": "true",
            "limit": "1",
            "fields": "MediaSources",
        ])
        let track = try #require(response.items?.first, "server has no audio items to test with")

        let stream = await resolveStream(client: client, config: config, itemId: track.id)

        // The whole point of the Apple profile: a FLAC library must direct
        // play, not transcode. A transcode here means the profile is wrong or
        // the server disagrees with it, and the fix is the profile, not this
        // test.
        #expect(stream.direct, "server chose to transcode \(track.name ?? track.id)")
        #expect(stream.playSessionId != nil)
        #expect(stream.url.absoluteString.contains("static=true"))

        // And the URL it produced must actually serve bytes. A URL that 404s
        // looks identical to a working one until playback is silent.
        var head = URLRequest(url: stream.url)
        head.httpMethod = "HEAD"
        let (_, headResponse) = try await URLSession.shared.data(for: head)
        let status = (headResponse as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200, "stream URL answered \(status)")
    }

    @Test func avFoundationCanDecodeTheStreamTheServerReturns() async throws {
        let (client, config) = try await signIn()
        let response: JfItemsResponse = try await client.get("/Items", params: [
            "userId": config.userId, "includeItemTypes": "Audio",
            "recursive": "true", "limit": "1",
        ])
        let track = try #require(response.items?.first)
        let stream = await resolveStream(client: client, config: config, itemId: track.id)

        // The question step three exists to answer. A 200 from the stream URL
        // only proves bytes arrive; this proves AVFoundation will decode them.
        // A profile claiming a codec AVPlayer cannot handle fails HERE rather
        // than as silence on a device.
        let asset = AVURLAsset(url: stream.url)
        let playable = try await asset.load(.isPlayable)
        #expect(playable, "AVFoundation will not play \(track.name ?? track.id)")

        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0, "asset reported no duration")

        // And it matches what Jellyfin says the track is, so this is the right
        // file and not, say, a truncated error body that happens to parse.
        if let expected = track.runTimeTicks {
            #expect(abs(duration - seconds(fromTicks: expected)) < 2.0,
                    "decoded \(duration)s, server says \(seconds(fromTicks: expected))s")
        }

        // The Mac's decoders are not an Apple TV's. This is a strong proxy for
        // the audio path, and no proof at all about video.
    }

    @Test func reportingLifecycleIsAcceptedByThisServerVersion() async throws {
        let (client, config) = try await signIn()
        let response: JfItemsResponse = try await client.get("/Items", params: [
            "userId": config.userId, "includeItemTypes": "Audio",
            "recursive": "true", "limit": "1",
        ])
        let track = try #require(response.items?.first)
        let stream = await resolveStream(client: client, config: config, itemId: track.id)

        var state = PlaybackState(itemId: track.id, positionTicks: 0,
                                  playSessionId: stream.playSessionId,
                                  mediaSourceId: stream.mediaSourceId,
                                  playMethod: stream.playMethod)

        // PlaybackReporter swallows errors on purpose, so calling it would
        // prove nothing. Post the same bodies through the raw path, where a
        // bad shape throws.
        try await client.postRaw("/Sessions/Playing", body: PlaybackReport(state))
        state.positionTicks = ticks(fromSeconds: 5)
        try await client.postRaw("/Sessions/Playing/Progress",
                                 body: PlaybackReport(state, eventName: "TimeUpdate"))
        try await client.postRaw("/Sessions/Playing/Stopped", body: StoppedReport(
            itemId: state.itemId, positionTicks: state.positionTicks,
            playSessionId: state.playSessionId, mediaSourceId: state.mediaSourceId))
    }
}
