import Testing
@testable import CascadeKit

// Ports the response-graph cases of test/eq-profile.test.ts.
@Suite struct EQGraphTests {
    @Test func bandsSpaceEvenlyWithAnInset() {
        #expect(EQGraph.x(0, of: 5, width: 260) == 20.8)
        #expect(abs(EQGraph.x(4, of: 5, width: 260) - (260 - 20.8)) < 1e-9)
        #expect(EQGraph.x(2, of: 5, width: 260) == 130)
        #expect(EQGraph.x(0, of: 1, width: 260) == 130)
    }

    @Test func dbAndYAreInverseAtTheLimitsAndTheMiddle() {
        #expect(EQGraph.y(12, height: 140) == 0)
        #expect(EQGraph.y(-12, height: 140) == 140)
        #expect(EQGraph.y(0, height: 140) == 70)
        for db in stride(from: -12.0, through: 12.0, by: 0.5) {
            #expect(EQGraph.db(y: EQGraph.y(db, height: 140), height: 140) == db, "\(db)")
        }
    }

    @Test func aCorruptGainNeverPlacesAPointOffTheGraph() {
        #expect(EQGraph.y(99, height: 140) == 0)
        #expect(EQGraph.y(-99, height: 140) == 140)
        #expect(EQGraph.y(.nan, height: 140) == 70)
        #expect(EQGraph.y(.infinity, height: 140) == 70)
    }

    @Test func aPointerIsBoundedAndSnapsToHalfADecibel() {
        #expect(EQGraph.db(y: -500, height: 140) == 12)
        #expect(EQGraph.db(y: 9999, height: 140) == -12)
        #expect(EQGraph.db(y: .nan, height: 140) == 0)
        #expect(EQGraph.db(y: 10, height: 0) == 0)
        let v = EQGraph.db(y: 33.3, height: 140)
        #expect((v * 2).rounded() == v * 2)
    }

    @Test func theCurveRunsThroughEveryPoint() {
        let gains = [7.0, 4, 0, -1, -1]
        let pts = EQGraph.points(gains, width: 260, height: 140)
        let curve = EQGraph.curve(gains, width: 260, height: 140)
        #expect(curve.count == 4)
        #expect(curve.map(\.to) == Array(pts.dropFirst()))
        #expect(EQGraph.curve([3], width: 260, height: 140).isEmpty)
        // A flat curve stays flat: every control point sits on the line.
        let flat = EQGraph.curve([0, 0, 0, 0, 0], width: 260, height: 140)
        #expect(flat.allSatisfy { $0.control1.y == 70 && $0.control2.y == 70 })
    }

    @Test func labelsComeFromTheBandFrequencies() {
        #expect(EQProfile.bands.map(EQGraph.label) == ["60 Hz", "250 Hz", "1 kHz", "4 kHz", "12 kHz"])
        #expect(EQGraph.label(1500) == "1.5 kHz")
    }

    @Test func keysMoveByTheDesktopsSteps() {
        #expect(EQGraph.db(after: .up, from: 0) == 0.5)
        #expect(EQGraph.db(after: .down, from: 0) == -0.5)
        #expect(EQGraph.db(after: .pageUp, from: 11) == 12)
        #expect(EQGraph.db(after: .pageDown, from: -11) == -12)
        #expect(EQGraph.db(after: .home, from: 3) == -12)
        #expect(EQGraph.db(after: .end, from: 3) == 12)
    }
}
