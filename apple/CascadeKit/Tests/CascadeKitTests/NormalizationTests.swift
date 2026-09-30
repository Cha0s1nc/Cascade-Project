import Testing
@testable import CascadeKit

// The desktop's normalization maths (test/normalization.test.ts).
struct NormalizationTests {
    @Test func decibelsToLinear() {
        #expect(abs(Normalization.linear(db: -6.0206) - 0.5) < 0.001)
        #expect(Normalization.linear(db: 0) == 1)
    }

    @Test func missingOrCorruptIsUnity() {
        #expect(Normalization.linear(db: nil) == 1)
        #expect(Normalization.linear(db: .nan) == 1)
        #expect(Normalization.linear(db: .infinity) == 1)
    }

    @Test func clampedBothWays() {
        #expect(abs(Normalization.linear(db: 34) - Normalization.linear(db: 12)) < 0.0001)
        #expect(abs(Normalization.linear(db: -60) - Normalization.linear(db: -24)) < 0.0001)
    }

    @Test func thePlayerOnlyCuts() {
        #expect(Normalization.playerVolume(db: 5) == 1)
        #expect(Normalization.playerVolume(db: -6.0206) < 0.501)
    }
}
