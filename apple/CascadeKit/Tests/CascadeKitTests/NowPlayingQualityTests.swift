import Foundation
import Testing
@testable import CascadeKit

// Flutter's qualityOf cases (flutter/lib/core/playback.dart), with AAC for a transcode.
struct NowPlayingQualityTests {
    private func detail(_ json: String) throws -> MediaDetail {
        try JSON.decoder.decode(MediaDetail.self, from: Data(json.utf8))
    }

    @Test func theFileItself() throws {
        let d = try detail(#"{"MediaSources":[{"Container":"flac","Bitrate":1012345,"MediaStreams":[{"Type":"Audio","Codec":"flac","BitDepth":24,"SampleRate":44100,"BitRate":1011000}]}]}"#)
        let q = NowPlayingQuality.of(d)
        #expect(q.map(\.label) == ["Format", "Bit depth", "Sample rate", "Bitrate"])
        #expect(q.map(\.value) == ["FLAC", "24-bit", "44.1 kHz", "1011 kbps"])
    }

    @Test func whatIsMissingIsLeftOut() throws {
        let d = try detail(#"{"MediaSources":[{"Container":"mp3,mpeg","MediaStreams":[{"Type":"Audio","SampleRate":48000}]}]}"#)
        #expect(NowPlayingQuality.of(d).map(\.value) == ["MP3", "48 kHz"])
        #expect(NowPlayingQuality.of(try detail("{}")).isEmpty)
        #expect(NowPlayingQuality.of(nil).isEmpty)
    }

    @Test func aTranscodeSaysWhatItBecame() throws {
        let d = try detail(#"{"MediaSources":[{"MediaStreams":[{"Type":"Audio","Codec":"alac"}]}]}"#)
        #expect(NowPlayingQuality.of(d, transcoding: true, transcodeBitrate: 256_000).map(\.value) == ["AAC", "256 kbps", "ALAC"])
        #expect(NowPlayingQuality.of(d, transcoding: true).map(\.value) == ["AAC", "ALAC"])
    }
}
