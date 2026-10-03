import Testing
@testable import CascadeKit

@Suite struct StreamingQualityTests {
    @Test func storedValuesAreValidated() {
        #expect(StreamingQuality(stored: 128_000) == .kbps128)
        #expect(StreamingQuality(stored: 0) == .original)
        // Nothing stored, a bitrate that is not a step, and the wrong type all
        // fall back to Original rather than reaching the server.
        #expect(StreamingQuality(stored: nil) == .original)
        #expect(StreamingQuality(stored: 123) == .original)
        #expect(StreamingQuality(stored: -1) == .original)
        #expect(StreamingQuality(stored: "320000") == .original)
    }

    @Test func theDesktopsStoredBitrateMapsOntoTheSteps() {
        #expect(StreamingQuality(electronBitrate: 140_000_000) == .original)
        #expect(StreamingQuality(electronBitrate: 320_000) == .kbps320)
        #expect(StreamingQuality(electronBitrate: "192000") == .kbps192)
        #expect(StreamingQuality(electronBitrate: 96_000) == .kbps96)
        // Between steps: the one below, so a cap is never loosened.
        #expect(StreamingQuality(electronBitrate: 200_000) == .kbps192)
        #expect(StreamingQuality(electronBitrate: 50_000) == .kbps96)
        // Nothing, zero and junk are Original, as is anything past the desktop's own Original.
        #expect(StreamingQuality(electronBitrate: nil) == .original)
        #expect(StreamingQuality(electronBitrate: 0) == .original)
        #expect(StreamingQuality(electronBitrate: "fast") == .original)
        #expect(StreamingQuality(stored: 140_000_000) == .original)
    }

    @Test func originalLeavesTheProfileAlone() {
        #expect(DeviceProfile.apple.capped(at: .original).maxStreamingBitrate == DeviceProfile.apple.maxStreamingBitrate)
    }

    @Test func aStepCapsTheProfile() {
        #expect(DeviceProfile.apple.capped(at: .kbps192).maxStreamingBitrate == 192_000)
    }

    @Test func labels() {
        #expect(StreamingQuality.original.label == "Original")
        #expect(StreamingQuality.kbps256.label == "256 kbps")
    }
}
