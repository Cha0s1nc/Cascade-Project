import Foundation
import Testing
@testable import CascadeKit

@Suite struct TelemetryTests {
    @Test func shipsDormant() {
        // Switching it on is a deliberate step with a checklist (src/core/telemetry.ts).
        #expect(Telemetry.url == nil)
        let defaults = UserDefaults(suiteName: "TelemetryTests.dormant")!
        defaults.removePersistentDomain(forName: "TelemetryTests.dormant")
        defaults.set(true, forKey: Telemetry.optInKey)
        #expect(!Telemetry.optedIn(defaults))
        Telemetry.countSong(defaults)
        #expect(defaults.object(forKey: Telemetry.songsKey) == nil)
        #expect(!SetupWizard.steps(seen: 0, needsLibraryStep: false).contains(.telemetry))
        #expect(SetupWizard.Step.telemetry.since == 6)
    }

    @Test func optingOutForgetsTheInstall() {
        let defaults = UserDefaults(suiteName: "TelemetryTests.optOut")!
        defaults.removePersistentDomain(forName: "TelemetryTests.optOut")
        Telemetry.setOptIn(true, defaults)
        let id = defaults.string(forKey: Telemetry.installIdKey)
        #expect(id.flatMap(UUID.init(uuidString:)) != nil)
        Telemetry.setOptIn(true, defaults)
        #expect(defaults.string(forKey: Telemetry.installIdKey) == id)
        defaults.set(3, forKey: Telemetry.songsKey)
        Telemetry.setOptIn(false, defaults)
        #expect(defaults.string(forKey: Telemetry.installIdKey) == nil)
        #expect(defaults.object(forKey: Telemetry.songsKey) == nil)
    }

    @Test func dueOnTheFirstRunThenOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(Telemetry.due(lastSent: 0, now: now))
        #expect(!Telemetry.due(lastSent: now.timeIntervalSince1970 - 1000, now: now))
        #expect(Telemetry.due(lastSent: now.timeIntervalSince1970 - Telemetry.interval, now: now))
    }

    @Test func pingClampsTheSongCount() {
        #expect(Telemetry.ping(installId: "id", songs: 12).songs == 12)
        #expect(Telemetry.ping(installId: "id", songs: -1).songs == 0)
        #expect(Telemetry.ping(installId: "id", songs: 1_000_000).songs == Telemetry.maxSongs)
    }
}
