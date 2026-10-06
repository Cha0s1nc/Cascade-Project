import Testing
@testable import CascadeKit

@Suite struct SetupWizardTests {
    typealias W = SetupWizard

    @Test func aFreshInstallWalksEveryStep() {
        #expect(W.steps(seen: 0, needsLibraryStep: true) == [.libraries, .crossfade, .quality, .theme, .translation])
        // No choice to make: no library screen.
        #expect(W.steps(seen: 0, needsLibraryStep: false) == [.crossfade, .quality, .theme, .translation])
    }

    @Test func anUpdateShowsOnlyWhatIsNewSinceTheRevisionItFinished() {
        #expect(W.steps(seen: 1, needsLibraryStep: true) == [.crossfade, .quality, .theme, .translation])
        #expect(W.steps(seen: 2, needsLibraryStep: true) == [.translation])
        #expect(W.steps(seen: 3, needsLibraryStep: true).isEmpty)
        #expect(W.steps(seen: 99, needsLibraryStep: true).isEmpty)
    }

    @Test func seenRevisionReadsTheRevisionOrTheOldBoolean() {
        #expect(W.seenRevision(wizardSeenRevision: 3, firstRunWizardSeen: nil) == 3)
        #expect(W.seenRevision(wizardSeenRevision: "2", firstRunWizardSeen: nil) == 2)
        #expect(W.seenRevision(wizardSeenRevision: nil, firstRunWizardSeen: true) == 1)
        #expect(W.seenRevision(wizardSeenRevision: nil, firstRunWizardSeen: "true") == 1)
        #expect(W.seenRevision(wizardSeenRevision: nil, firstRunWizardSeen: nil) == 0)
        // Garbage and non-positive values fall through to the boolean, then to a fresh install.
        #expect(W.seenRevision(wizardSeenRevision: -1, firstRunWizardSeen: nil) == 0)
        #expect(W.seenRevision(wizardSeenRevision: "x", firstRunWizardSeen: true) == 1)
        #expect(W.seenRevision(wizardSeenRevision: 0, firstRunWizardSeen: false) == 0)
    }

    @Test func theLibraryStepNeedsARealChoice() {
        #expect(!W.needsLibraryStep(collectionTypes: ["music", "movies", "tvshows"]))
        #expect(W.needsLibraryStep(collectionTypes: ["music", "music"]))
        #expect(W.needsLibraryStep(collectionTypes: ["music", "musicvideos"]))
        #expect(W.needsLibraryStep(collectionTypes: ["movies", "movies", nil]))
        #expect(!W.needsLibraryStep(collectionTypes: []))
    }

    @Test func theVideoIntroOnlyAsksWhenThereIsAnUnmadeChoice() {
        #expect(W.videoIntroNeeded(movieLibraries: 2, showLibraries: 0, movieChoice: [], showChoice: []))
        #expect(!W.videoIntroNeeded(movieLibraries: 2, showLibraries: 0, movieChoice: ["a"], showChoice: []))
        #expect(!W.videoIntroNeeded(movieLibraries: 1, showLibraries: 1, movieChoice: [], showChoice: []))
        #expect(W.videoIntroNeeded(movieLibraries: 1, showLibraries: 3, movieChoice: [], showChoice: []))
    }
}
