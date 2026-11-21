import Foundation
import Testing
@testable import CascadeKit

// Flutter's homeVoice wording (flutter/lib/ui/pages/home.dart), so the apps match.
struct HomeVoiceTests {
    @Test func wording() {
        #expect(HomeVoice.line(songs: 4212, week: 61) == "4,212 songs on your server. 61 of them played this week.")
        #expect(HomeVoice.line(songs: 1, week: 0) == "1 song on your server. Nothing played this week yet.")
        #expect(HomeVoice.line(songs: 0, week: 3) == "Your server has no songs yet.")
    }

    @Test func countsOnlyThisWeeksPlays() {
        func song(_ played: String?) -> JfItem {
            var data = JfUserData()
            data.lastPlayedDate = played
            return JfItem(id: UUID().uuidString, userData: data)
        }
        let now = try! Date.ISO8601FormatStyle().parse("2026-11-20T12:00:00Z")
        let played = [
            song("2026-11-19T08:30:12.1234567Z"), // Jellyfin's seven digits
            song("2026-11-14T12:00:01Z"),
            song("2026-11-13T11:59:59.000Z"), // just over a week
            song(nil),
            song("not a date"),
        ]
        #expect(HomeVoice.playedThisWeek(played, now: now) == 2)
    }
}
