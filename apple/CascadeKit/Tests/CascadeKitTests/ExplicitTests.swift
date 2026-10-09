import Testing
@testable import CascadeKit

struct ExplicitTests {
    @Test func onlyExplicitAnswersMark() {
        #expect(ExplicitRatings.explicitIds(["a": "explicit", "b": "clean", "c": "EXPLICIT"]) == ["a"])
    }
}
