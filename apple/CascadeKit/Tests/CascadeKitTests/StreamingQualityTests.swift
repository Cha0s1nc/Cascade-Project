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
