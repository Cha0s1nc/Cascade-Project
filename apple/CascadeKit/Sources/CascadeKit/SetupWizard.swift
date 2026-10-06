import Foundation

/// Which first-run wizard steps to show, keyed off a revision rather than a
/// boolean or the app version: the desktop's WIZARD_REVISION and
/// FIRSTRUN_STEP_REVISION in renderer.js.
///
/// Bump `revision` when the wizard starts covering something existing users
/// have not been shown. Everyone whose stored revision is behind sees only the
/// steps newer than the one they last finished, once. Re-showing it is only
/// safe because every step seeds from the CURRENT live value, so clicking
/// straight through changes nothing: never add a step that writes a default
/// on entry.
public enum SetupWizard {
    /// 1: the original first-run-only wizard.
    /// 2: re-shown to everyone upgrading, for video libraries, crossfade, the
    ///    streaming cap and album art accent.
    /// 3: lyric translation, whose switch is disclosed here before it can run.
    public static let revision = 3

    public enum Step: String, CaseIterable, Sendable {
        case libraries, crossfade, quality, theme, translation

        /// The revision this step arrived in.
        public var since: Int {
            switch self {
            case .libraries: 1
            case .crossfade, .quality, .theme: 2
            case .translation: 3
            }
        }
    }

    /// Which revision this install has been shown. Absent means a fresh
    /// install (0), or one from before revisions existed, which counts as 1 if
    /// it had finished the wizard. Both values are stored untrusted.
    public static func seenRevision(wizardSeenRevision: Any?, firstRunWizardSeen: Any?) -> Int {
        let n: Int?
        switch wizardSeenRevision {
        case let i as Int: n = i
        case let s as String: n = Int(s)
        default: n = nil
        }
        if let n, n > 0 { return n }
        let seen: Bool
        switch firstRunWizardSeen {
        case let b as Bool: seen = b
        case let s as String: seen = s == "true"
        default: seen = false
        }
        return seen ? 1 : 0
    }

    /// The steps to show, none when this install is up to date. The library
    /// step is only worth a screen when there is an actual choice to make.
    public static func steps(seen: Int, needsLibraryStep: Bool) -> [Step] {
        guard seen < revision else { return [] }
        return Step.allCases.filter { ($0 != .libraries || needsLibraryStep) && (seen == 0 || $0.since > seen) }
    }

    /// Whether a library choice exists on this server: more than one library of
    /// some kind. `kinds` are the CollectionType values of the user's views.
    public static func needsLibraryStep(collectionTypes kinds: [String?]) -> Bool {
        let music = kinds.filter { $0 == "music" || $0 == "musicvideos" }.count
        let movies = kinds.filter { $0 == "movies" }.count
        let shows = kinds.filter { $0 == "tvshows" }.count
        return music > 1 || movies > 1 || shows > 1
    }

    /// The old video intro card's rule: a category needs it only when it has a
    /// choice (more than one library) that has not been made yet.
    public static func videoIntroNeeded(movieLibraries: Int, showLibraries: Int, movieChoice: [String], showChoice: [String]) -> Bool {
        (movieLibraries > 1 && movieChoice.isEmpty) || (showLibraries > 1 && showChoice.isEmpty)
    }
}
