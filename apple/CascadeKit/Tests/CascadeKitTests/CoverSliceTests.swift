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
}
