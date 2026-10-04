import Testing
import Foundation
@testable import CascadeKit

private func item(position: Int? = nil, runtime: Int? = nil, played: Bool? = nil) -> JfItem {
    JfItem(id: "x", runTimeTicks: runtime,
           userData: JfUserData(playbackPositionTicks: position, played: played))
}

@Suite("resumeTicks")
struct ResumeTicksTests {
    @Test func noPositionStartsAtZero() {
        #expect(resumeTicks(for: item()) == 0)
        #expect(resumeTicks(for: nil) == 0)
        #expect(resumeTicks(for: item(position: 0)) == 0)
    }

    @Test func honoursAStoredPosition() {
        #expect(resumeTicks(for: item(position: 300_000_000, runtime: 2_400_000_000)) == 300_000_000)
    }

    @Test func playedItemsRestart() {
        #expect(resumeTicks(for: item(position: 300_000_000, runtime: 2_400_000_000, played: true)) == 0)
    }

    @Test func positionPastTheCompleteRatioRestarts() {
        // 96% through: a leftover from finishing the track, not an intent.
        #expect(resumeTicks(for: item(position: 2_304_000_000, runtime: 2_400_000_000)) == 0)
        // 94%: still worth resuming.
        #expect(resumeTicks(for: item(position: 2_256_000_000, runtime: 2_400_000_000)) == 2_256_000_000)
    }
}

@Suite("withStartTicks")
struct StartTicksTests {
    @Test func zeroOrLessLeavesTheUrlAlone() {
        let url = "https://s/videos/1/master.m3u8?a=b"
        #expect(withStartTicks(url, 0) == url)
        #expect(withStartTicks(url, -5) == url)
    }

    @Test func appendsToAnExistingQuery() {
        let out = withStartTicks("https://s/videos/1/master.m3u8?a=b", 1234)
        #expect(out.contains("a=b"))
        #expect(out.contains("StartTimeTicks=1234"))
    }

    @Test func replacesRatherThanDuplicating() {
        // Scrubbing twice must not leave two offsets in the URL, which the
        // server resolves by taking one of them and not necessarily the last.
        let once = withStartTicks("https://s/x?StartTimeTicks=1", 999)
        #expect(once.components(separatedBy: "StartTimeTicks").count == 2)
        #expect(once.contains("StartTimeTicks=999"))
    }
}

@Suite("Apple device profile")
struct DeviceProfileTests {
    @Test func claimsFlacButNeverOpusOrVorbis() throws {
        let json = String(data: try JSON.encoder.encode(DeviceProfile.apple), encoding: .utf8)!
        // A claimed codec AVPlayer cannot decode plays silently rather than
        // erroring, which is the single worst failure mode here.
        #expect(!json.lowercased().contains("opus"))
        #expect(!json.lowercased().contains("vorbis"))
        #expect(DeviceProfile.apple.directPlayAudioCodecs.contains("flac"))
    }

    @Test func wavEntryHasNoAudioCodec() {
        let wav = DeviceProfile.apple.directPlayProfiles.first { $0.container == "wav" }
        // No AudioCodec means "any codec in this container", which beats
        // guessing which pcm_* spelling this server reports.
        #expect(wav?.audioCodec == nil)
    }

    @Test func transcodesToHlsAac() {
        let t = DeviceProfile.apple.transcodingProfiles.first
        #expect(t?.streamProtocol == "hls")
        #expect(t?.audioCodec == "aac")
        #expect(t?.container == "ts")
    }

    @Test func bitrateIsAWirelessNumberOnPhonesAndTheDesktopsOnTheMac() {
        #if os(macOS)
        #expect(DeviceProfile.apple.maxStreamingBitrate == 140_000_000)
        #else
        #expect(DeviceProfile.apple.maxStreamingBitrate == 20_000_000)
        #endif
    }
}

@Suite("Server errors")
struct ErrorMessageTests {
    private func response(_ status: Int, contentType: String = "text/plain") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://s/x")!, statusCode: status,
                        httpVersion: nil, headerFields: ["Content-Type": contentType])!
    }

    @Test func keepsShortPlainText() {
        let msg = errorMessage(response: response(400), body: Data("Bad password".utf8))
        #expect(msg == "Bad password")
    }

    @Test func fallsBackToTheStatusLineForHtml() {
        // A proxy in front of a dead server answers with a whole error page,
        // and dumping that into an alert fills the screen.
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let msg = errorMessage(response: response(502, contentType: "text/html"), body: html)
        #expect(msg.hasPrefix("502"))
        #expect(!msg.contains("<"))
    }

    @Test func capsAVeryLongBody() {
        let msg = errorMessage(response: response(500), body: Data(String(repeating: "a", count: 5000).utf8))
        #expect(msg.count <= 301)
    }
}

@Suite("Playback reports")
struct ReportTests {
    @Test func clampsVolumeToJellyfinScale() throws {
        var s = PlaybackState(itemId: "a", positionTicks: 10, volumeLevel: 250)
        #expect(PlaybackReport(s).volumeLevel == 100)
        s.volumeLevel = -5
        #expect(PlaybackReport(s).volumeLevel == 0)
    }

    @Test func neverReportsANegativePosition() {
        let s = PlaybackState(itemId: "a", positionTicks: -100)
        #expect(PlaybackReport(s).positionTicks == 0)
    }

    @Test func carriesTheSessionIdsThatTieToTheServerSession() throws {
        let s = PlaybackState(itemId: "a", positionTicks: 0,
                              playSessionId: "sess", mediaSourceId: "src", playMethod: .transcode)
        let json = String(data: try JSON.encoder.encode(PlaybackReport(s)), encoding: .utf8)!
        #expect(json.contains("\"PlaySessionId\":\"sess\""))
        #expect(json.contains("\"MediaSourceId\":\"src\""))
        #expect(json.contains("\"PlayMethod\":\"Transcode\""))
    }
}

@Suite("Direct stream URL")
struct DirectStreamTests {
    private let config = ServerConfig(url: "https://s/", token: "TOK", userId: "U", deviceId: "D")

    @Test func trailingSlashOnTheServerUrlIsDropped() {
        // Otherwise every path becomes a double slash, which some proxies
        // answer with a redirect that drops the auth header.
        #expect(config.url == "https://s")
    }

    @Test func carriesTheContainerExtension() throws {
        var source = MediaSource()
        source.id = "src"
        source.container = "flac"
        let url = try #require(directStreamUrl(config: config, itemId: "item",
                                               source: source, playSessionId: "sess"))
        // Without the extension some servers re-probe the file every request.
        #expect(url.path == "/Audio/item/stream.flac")
        #expect(url.query!.contains("static=true"))
        #expect(url.query!.contains("mediaSourceId=src"))
        #expect(url.query!.contains("PlaySessionId=sess"))
    }

    @Test func takesTheFirstOfSeveralContainers() throws {
        var source = MediaSource()
        source.container = "m4a,mp4"
        let url = try #require(directStreamUrl(config: config, itemId: "i",
                                               source: source, playSessionId: nil))
        #expect(url.path == "/Audio/i/stream.m4a")
    }
}

@Suite("Tick conversion")
struct TickTests {
    @Test func roundTripsSeconds() {
        #expect(ticks(fromSeconds: 42.5) == 425_000_000)
        #expect(seconds(fromTicks: 425_000_000) == 42.5)
        #expect(ticks(fromSeconds: -1) == 0)
    }
}
