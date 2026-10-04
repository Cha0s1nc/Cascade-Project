import Testing
import Foundation
@testable import CascadeKit

// The desktop's test/radio.test.ts, ported case for case.
struct RadioTests {
    private let config = ServerConfig(url: "http://server", token: "tok", userId: "u1", deviceId: "d1")

    @Test func isRadioItemIsTrueOnlyForALiveTvChannel() {
        #expect(isRadioItem(JfItem(id: "1", type: "TvChannel")))
        #expect(!isRadioItem(JfItem(id: "1", type: "Audio")))
        #expect(!isRadioItem(JfItem(id: "1", type: "Movie")))
        #expect(!isRadioItem(nil))
    }

    @Test func streamUrlCarriesTheMediaSourceAndSessionNeverStatic() throws {
        let url = try #require(buildRadioStreamUrl(
            config: config, channelId: "chan1",
            source: RadioSource(id: "src1", container: "mp3", liveStreamId: "live1"), playSessionId: "sess1"))
        #expect(url.absoluteString.hasPrefix("http://server/Audio/chan1/stream.mp3?"))
        #expect(url.absoluteString.contains("ApiKey=tok"))
        #expect(url.absoluteString.contains("mediaSourceId=src1"))
        #expect(url.absoluteString.contains("LiveStreamId=live1"))
        #expect(url.absoluteString.contains("PlaySessionId=sess1"))
        #expect(!url.absoluteString.lowercased().contains("static"))
    }

    @Test func streamUrlToleratesASourceWithNoContainerOrSession() {
        let url = buildRadioStreamUrl(config: config, channelId: "chan1", source: RadioSource(), playSessionId: nil)
        #expect(url?.absoluteString == "http://server/Audio/chan1/stream?ApiKey=tok")
    }

    @Test func aContainerListUsesItsFirstEntry() {
        let url = buildRadioStreamUrl(config: config, channelId: "c", source: RadioSource(container: "aac,mp3"), playSessionId: nil)
        #expect(url?.absoluteString.hasPrefix("http://server/Audio/c/stream.aac?") == true)
    }
}
