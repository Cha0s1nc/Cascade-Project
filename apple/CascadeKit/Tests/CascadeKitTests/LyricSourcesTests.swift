import Foundation
import Testing
@testable import CascadeKit

private let ms = Lyrics.ticksPerSecond / 1000

// parseKrc and the Spotify id cases are ported from the desktop's
// test/lyrics.test.ts and test/spicy-lyrics.test.ts.
struct LyricSourcesTests {
    @Test func krcWordOffsetsAreRelativeToTheLineStart() throws {
        let out = Lyrics.parseKrc("[1000,2000]<0,500,0>Hi<500,500,0> there")
        #expect(out.count == 1)
        let line = try #require(out.first)
        #expect(line.start == 1000 * ms)
        #expect(line.text == "Hi there")
        // The space before "there" moves onto "Hi", the parseLRC convention.
        #expect(line.words?.map(\.text) == ["Hi ", "there"])
        #expect(line.words?.map(\.start) == [1000 * ms, 1500 * ms])
        #expect(line.words?.map(\.end) == [1500 * ms, 2000 * ms])
    }

    @Test func krcSkipsTagLines() {
        let out = Lyrics.parseKrc("[ti:Title]\n[offset:0]\n[100,200]<0,200,0>x")
        #expect(out.map(\.text) == ["x"])
    }

    @Test func kugouContentDecrypts() throws {
        // Built the way Kugou builds it: zlib (header, DEFLATE, checksum),
        // XORed with the key, behind "krc1", in base64.
        let krc = "[ti:t]\n[1000,2000]<0,500,0>Hi<500,500,0> there\n"
        let deflate = try (Data(krc.utf8) as NSData).compressed(using: .zlib) as Data
        var zlib = [UInt8]([0x78, 0x9C]) + [UInt8](deflate) + [0, 0, 0, 0]
        let key: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
        for i in zlib.indices { zlib[i] ^= key[i % key.count] }
        let content = (Data("krc1".utf8) + Data(zlib)).base64EncodedString()
        #expect(Kugou.decrypt(base64: content) == krc)
        #expect(Kugou.decrypt(base64: "not base64!") == nil)
    }

    @Test func creditLinesAreDropped() {
        let lines = ["Viva La Vida - Coldplay", "Written by: Chris Martin", "作词：某人", "Composed By : x",
                     "I used to rule the world", "Lyrics are words"].map { LyricLine(start: 0, text: $0, words: nil) }
        #expect(Lyrics.droppingCredits(lines, title: "viva la vida").map(\.text) == ["I used to rule the world", "Lyrics are words"])
    }

    @Test func lrclibPrefersSyncedThenPlainAndFlagsInstrumentals() throws {
        let synced = try #require(LRCLIB.parse(["syncedLyrics": "[00:01.00]one", "plainLyrics": "one"]))
        #expect(synced.synced && synced.lines.map(\.text) == ["one"])
        let plain = try #require(LRCLIB.parse(["syncedLyrics": NSNull(), "plainLyrics": "one\n\n two \n"]))
        #expect(!plain.synced && plain.lines.map(\.text) == ["one", "two"])
        #expect(LRCLIB.parse(["instrumental": true])?.instrumental == true)
        #expect(LRCLIB.parse(["plainLyrics": ""]) == nil)
    }

    @Test func staticSpicySyncIsUntimed() throws {
        let out = try #require(SpicyLyrics.convert(["Type": "Static", "source": "spotify",
                                                    "Lines": [["Text": "one"], ["Text": "  "], ["Text": "two"]]]))
        #expect(!out.synced)
        #expect(out.lines.map(\.text) == ["one", "two"])
    }

    @Test func pluginInfoDefaults() throws {
        let old = try JSON.decoder.decode(CascadePluginInfo.self, from: Data("{\"name\":\"x\"}".utf8))
        #expect(old == CascadePluginInfo(capabilities: [], spotifyLinkServerWide: true))
        let new = try JSON.decoder.decode(CascadePluginInfo.self, from: Data(
            "{\"capabilities\":[\"syllable\",\"spotify-link\"],\"spotifyLinkServerWide\":false}".utf8))
        #expect(new.spicy && new.spotifyLink && !new.spotifyLinkServerWide)
    }

    @Test func spotifyTrackIdsComeOutOfLinksURIsAndBareIds() {
        let id = "2VOomzT6VavJOGBeySqaMc"
        for ok in [id, " \(id) ", "spotify:track:\(id)", "https://open.spotify.com/track/\(id)",
                   "https://open.spotify.com/track/\(id)?si=abc123", "open.spotify.com/intl-de/track/\(id)",
                   "https://open.spotify.com/embed/track/\(id)"] {
            #expect(Spotify.trackId(ok) == id, "\(ok)")
        }
        for bad in ["", "nope", "https://open.spotify.com/album/\(id)", "https://open.spotify.com/playlist/\(id)",
                    "https://evil.example/open.spotify.com/track/\(id)", "\(id)x", "spotify:track:short"] {
            #expect(Spotify.trackId(bad) == nil, "\(bad)")
        }
    }
}
