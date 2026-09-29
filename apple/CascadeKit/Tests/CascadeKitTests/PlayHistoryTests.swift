import Foundation
import Testing
@testable import CascadeKit

// Ported from the desktop's groupByDay tests, in a fixed time zone and locale.
struct PlayHistoryTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private let locale = Locale(identifier: "en_US")

    private func play(_ id: String, _ when: String?) -> JfItem {
        var data = JfUserData()
        data.lastPlayedDate = when
        return JfItem(id: id, name: id, type: "Audio", userData: data)
    }

    @Test func readsJellyfinsSevenDigitFractions() {
        #expect(PlayHistory.date("2026-09-29T14:03:12.1234567Z") == PlayHistory.date("2026-09-29T14:03:12Z"))
        #expect(PlayHistory.date("2026-09-29T14:03:12Z") != nil)
        #expect(PlayHistory.date("yesterday") == nil)
        #expect(PlayHistory.date(nil) == nil)
    }

    @Test func groupsByLocalDayWithFriendlyLabels() {
        // 2026-09-29 10:00 in Chicago is 15:00Z.
        let now = PlayHistory.date("2026-09-29T15:00:00Z")!
        let items = [
            play("a", "2026-09-29T14:00:00.1234567Z"),   // today
            play("b", "2026-09-29T04:30:00Z"),           // 11:30 pm on the 28th in Chicago: yesterday, not today
            play("c", "2026-09-20T12:00:00Z"),
            play("bad", "not a date"),
            play("d", "2025-12-31T18:00:00Z"),
        ]
        let days = PlayHistory.byDay(items, now: now, calendar: calendar, locale: locale)
        #expect(days.map(\.label) == ["Today", "Yesterday", "September 20", "December 31, 2025"])
        #expect(days.map { $0.items.map(\.id) } == [["a"], ["b"], ["c"], ["d"]])
    }

    @Test func mergedLibrariesComeBackNewestFirst() {
        let items = [play("old", "2026-01-01T00:00:00Z"), play("new", "2026-09-01T00:00:00.5Z"), play("none", nil)]
        #expect(PlayHistory.newestFirst(items).map(\.id) == ["new", "old", "none"])
    }
}
