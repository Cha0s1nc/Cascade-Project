import Testing
@testable import CascadeKit

// Ported from the desktop's test/crossfade.test.ts.
struct CrossfadeTests {
    @Test func theEnvelopeKeepsPowerConstant() {
        for step in 0...20 {
            let g = Crossfade.gains(at: Double(step) / 20)
            #expect(abs(g.out * g.out + g.in * g.in - 1) < 1e-5)
        }
        #expect(Crossfade.gains(at: 0) == (1, 0))
        let end = Crossfade.gains(at: 1)
        #expect(abs(end.out) < 1e-6 && end.in == 1)
        #expect(Crossfade.gains(at: -1) == (1, 0))
    }

    @Test func aFadeNeverOutrunsTheTrack() {
        #expect(Crossfade.duration(configured: 6, remaining: 20) == 6)
        #expect(Crossfade.duration(configured: 6, remaining: 3) == 3)
        #expect(Crossfade.duration(configured: 6, remaining: 0.5) == nil)
        #expect(Crossfade.duration(configured: 0.5, remaining: 20) == nil)
        #expect(Crossfade.duration(configured: 6, remaining: .infinity) == 6)
        #expect(Crossfade.duration(configured: 0, remaining: .nan) == nil)
    }
}
