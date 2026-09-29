import Foundation

/// The listening history screen's logic: the desktop's History view
/// (renderer.js loadHistory, groupByDay in src/core/library-browse.ts).
public enum PlayHistory {
    /// One calendar day's plays, newest first.
    public struct Day: Identifiable, Sendable {
        public let label: String
        public let items: [JfItem]
        public var id: String { label }
    }

    /// A Jellyfin date. They carry seven fractional digits
    /// ("2026-09-29T14:03:12.1234567Z"), which ISO8601DateFormatter will not
    /// read, so the fraction is dropped: to the second is plenty for days.
    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string.replacing(/\.\d+/, with: ""))
    }

    /// Played songs newest first. Several libraries come back one after the
    /// other, each in its own order, so the merged list is put back in one.
    public static func newestFirst(_ items: [JfItem]) -> [JfItem] {
        items.map { ($0, date($0.userData?.lastPlayedDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Newest-first plays grouped by the local day they were last played on:
    /// Today, Yesterday, then dates, with the year only when it is not this
    /// one. A play at 11 pm stays on its own day (local midnight, not UTC). A
    /// song with no readable play date is left out rather than guessed at.
    public static func byDay(_ items: [JfItem], now: Date = .now, calendar: Calendar = .current,
                             locale: Locale = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var days: [(start: Date, items: [JfItem])] = []
        for item in items {
            guard let played = date(item.userData?.lastPlayedDate) else { continue }
            let start = calendar.startOfDay(for: played)
            if days.last?.start == start {
                days[days.count - 1].items.append(item)
            } else {
                days.append((start, [item]))
            }
        }
        return days.map { day in
            let ago = calendar.dateComponents([.day], from: day.start, to: today).day ?? 0
            let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            let label = switch ago {
            case 0: "Today"
            case 1: "Yesterday"
            default: calendar.isDate(day.start, equalTo: today, toGranularity: .year)
                ? day.start.formatted(style.month(.wide).day())
                : day.start.formatted(style.month(.wide).day().year())
            }
            return Day(label: label, items: day.items)
        }
    }
}

public extension JellyfinClient {
    /// This user's played songs, newest first, capped: the full history of
    /// a long-used server is tens of thousands of rows.
    ///
    /// ponytail: the newest `limit` only, where the desktop pages to the end.
    /// Page it here too if anyone scrolls past a thousand plays.
    func playHistory(limit: Int = 1000) async throws -> [JfItem] {
        PlayHistory.newestFirst(try await itemsAcrossLibraries([
            "userId": currentConfig.userId, "recursive": "true",
            "includeItemTypes": "Audio", "filters": "IsPlayed",
            "sortBy": "DatePlayed", "sortOrder": "Descending",
            "fields": "DateCreated,PrimaryImageAspectRatio", "limit": String(limit),
        ]))
    }
}
