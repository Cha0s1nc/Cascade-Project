import Foundation

/// The geometry of the settings equalizer's response graph: the desktop's
/// "Response-graph geometry" in src/core/eq-profile.ts. Everything about
/// turning band gains into points and a pointer position back into a gain
/// lives here, pure and tested, so the view only draws what this returns.
public enum EQGraph {
    /// Even x position for band `i` of `count`, inset a little so the first
    /// and last points are not clipped against the edge. Bands are spaced
    /// evenly rather than by true log frequency: with five fixed points the
    /// two look almost the same and even spacing is simpler.
    public static func x(_ i: Int, of count: Int, width: Double) -> Double {
        guard count > 1 else { return width / 2 }
        let inset = width * 0.08
        return inset + Double(i) / Double(count - 1) * (width - inset * 2)
    }

    /// A gain to a y position: +12 dB at the top (0), -12 dB at the bottom
    /// (height). Clamped first, so a corrupt profile cannot place a point
    /// outside the graph.
    public static func y(_ db: Double, height: Double) -> Double {
        let clamped = EQProfile.clamp(db.isFinite ? db : 0)
        return height * (1 - (clamped + EQProfile.gainLimit) / (2 * EQProfile.gainLimit))
    }

    /// The inverse of `y`: a pointer position back to a gain, clamped to the
    /// limit and rounded to the 0.5 dB step. The one function between a mouse
    /// or key event and a filter's gain, so it bounds the result itself.
    public static func db(y: Double, height: Double) -> Double {
        let bounded = max(0, min(height, y.isFinite ? y : height / 2))
        let ratio = height == 0 ? 0.5 : 1 - bounded / height
        let db = ratio * (2 * EQProfile.gainLimit) - EQProfile.gainLimit
        return EQProfile.clamp((db * 2).rounded() / 2)
    }

    public struct Point: Equatable, Sendable { public var x: Double; public var y: Double }

    /// One cubic Bezier piece of the curve, ending at `to`.
    public struct Segment: Equatable, Sendable {
        public var control1: Point, control2: Point, to: Point
    }

    /// A smooth curve through the band points: a Catmull-Rom spline turned
    /// into cubic Beziers, the standard dependency-free way to draw a curve
    /// through a few fixed points instead of joining them with straight lines.
    /// The path starts at the first of `points`.
    public static func points(_ gains: [Double], width: Double, height: Double) -> [Point] {
        gains.indices.map { Point(x: x($0, of: gains.count, width: width), y: y(gains[$0], height: height)) }
    }

    public static func curve(_ gains: [Double], width: Double, height: Double) -> [Segment] {
        let pts = points(gains, width: width, height: height)
        guard pts.count > 1 else { return [] }
        return (0..<pts.count - 1).map { i in
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            // The Catmull-Rom to Bezier tangent factor is 1/6.
            return Segment(control1: Point(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                           control2: Point(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                           to: p2)
        }
    }

    /// A band's frequency as a short label: "60 Hz", "1 kHz", "12 kHz".
    public static func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(hz / 1000 == (hz / 1000).rounded() ? String(Int(hz / 1000)) : String(hz / 1000)) kHz" : "\(Int(hz)) Hz"
    }

    /// The gain a key press moves a point to, as the desktop's keys do: arrows
    /// 0.5 dB, Page keys 3 dB, Home and End to the limits. Nil for any other key.
    public enum Key: Sendable { case up, down, pageUp, pageDown, home, end }

    public static func db(after key: Key, from db: Double) -> Double {
        switch key {
        case .up: EQProfile.clamp(db + 0.5)
        case .down: EQProfile.clamp(db - 0.5)
        case .pageUp: EQProfile.clamp(db + 3)
        case .pageDown: EQProfile.clamp(db - 3)
        case .home: -EQProfile.gainLimit
        case .end: EQProfile.gainLimit
        }
    }
}
