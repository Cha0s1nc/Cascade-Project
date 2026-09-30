import Foundation

/// Jellyfin's NormalizationGain (dB, from its loudness scan) as a volume
/// multiplier: the desktop's src/core/normalization.ts.
public enum Normalization {
    public enum Mode: String, CaseIterable, Sendable {
        case off, track, album
    }

    /// A boost past this is more likely to distort or startle than to help:
    /// the test library has an album scanned at +34 dB.
    public static let maxBoostDb = 12.0
    /// Server data, so clamped even though a cut cannot clip.
    public static let maxCutDb = 24.0

    /// The linear multiplier for a gain, clamped; nil or not a number means
    /// the track plays at its own level rather than a guess.
    public static func linear(db: Double?) -> Float {
        guard let db, db.isFinite else { return 1 }
        return Float(pow(10, min(maxBoostDb, max(-maxCutDb, db)) / 20))
    }

    /// What AVPlayer's own volume can apply, for an item with no audio tap
    /// (the EQ is off, or an HLS transcode): it stops at 1, so only cuts are
    /// heard. A tapped item takes `linear`, boosts included.
    public static func playerVolume(db: Double?) -> Float {
        min(1, linear(db: db))
    }
}
