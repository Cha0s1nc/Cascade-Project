import Testing
@testable import CascadeKit

struct CoverSliceTests {
    @Test func slicesInHoldsThenSlidesOff() {
        #expect(CoverSlice.cut(at: 0, fade: 6) == 2)
        #expect(CoverSlice.cut(at: 0.4, fade: 6)! < 2 && CoverSlice.cut(at: 0.4, fade: 6)! > 1)
        #expect(CoverSlice.cut(at: 0.8, fade: 6) == 1)
        #expect(CoverSlice.cut(at: 5.9, fade: 6) == 1)
        let leaving = CoverSlice.cut(at: 6.6, fade: 6)!
        #expect(leaving > 0 && leaving < 1)
        #expect(CoverSlice.cut(at: 7.2, fade: 6) == nil)
    }

    @Test func aShortFadeSlicesInWithinIt() {
        #expect(CoverSlice.cut(at: 0.5, fade: 0.5) == 1)
    }

    @Test func aFadeCutShortSlidesOutFromWhereItIs() {
        // Cut 0.2 s in, still near the corner: it leaves from there, quicker.
        let at = CoverSlice.cut(at: 0.2, fade: 6)!
        #expect(CoverSlice.cut(at: 0.2, fade: 6, cutAt: 0.2) == at)
        #expect(CoverSlice.cut(at: 0.25, fade: 6, cutAt: 0.2)! < at)
        #expect(CoverSlice.cut(at: 0.2 + 1.2, fade: 6, cutAt: 0.2) == nil)
    }

    @Test func theSeamSettlesThenFades() {
        #expect(CoverSlice.seam(at: 0, fade: 6) == 1)
        #expect(CoverSlice.seam(at: 3, fade: 6) == 0.55)
        #expect(CoverSlice.seam(at: 6 + 1.19, fade: 6) < 0.05)
    }

    @Test func theHoldPointAndSweep() {
        #expect(CoverSlice.cut(at: 3, fade: 6, hold: .old) == 1.4)
        #expect(CoverSlice.cut(at: 3, fade: 6, hold: .new) == 0.6)
        // A sweep crosses the whole fade, half way at half time, and is done when it ends.
        #expect(abs(CoverSlice.cut(at: 3, fade: 6, hold: .sweep)! - 1) < 1e-9)
        #expect(CoverSlice.cut(at: 6, fade: 6, hold: .sweep) == nil)
        // Cut short mid-sweep, it slides out from there.
        let at = CoverSlice.cut(at: 1.5, fade: 6, hold: .sweep)!
        #expect(CoverSlice.cut(at: 1.5, fade: 6, cutAt: 1.5, hold: .sweep) == at)
    }

    @Test func easingsRunZeroToOne() {
        for e in CoverSlice.Easing.allCases {
            #expect(e.into(0) == 0 && abs(e.into(1) - 1) < 1e-9 && e.out(0) == 0 && abs(e.out(1) - 1) < 1e-9)
            #expect(abs(e.out(0.5) - 0.5) < 1e-9)
        }
        #expect(CoverSlice.Easing.linear.into(0.25) == 0.25)
    }
}
