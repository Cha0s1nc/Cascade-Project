import Foundation

/// Home's line under the greeting, the Personality v1 voice: "4,212 songs on your
/// server. 61 of them played this week." Worded as Flutter's homeVoice
/// (flutter/lib/ui/pages/home.dart), so both apps say the same thing.
public enum HomeVoice {
    public static func line(songs: Int, week: Int) -> String {
        if songs == 0 { return "Your server has no songs yet." }
        let first = "\(songs.formatted(.number.locale(Locale(identifier: "en_US")))) \(songs == 1 ? "song" : "songs") on your server."
        return week == 0 ? "\(first) Nothing played this week yet." : "\(first) \(week) of them played this week."
    }

    /// Songs among `played` whose last play is within the seven days before `now`.
    /// Jellyfin keeps only the last play per song, so a song played twice counts once.
    public static func playedThisWeek(_ played: [JfItem], now: Date = .now) -> Int {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        return played.count { item in
            guard let raw = item.userData?.lastPlayedDate, let date = parse(raw) else { return false }
            return date > weekAgo
        }
    }

    /// Jellyfin's dates carry fractional seconds (seven digits) or none.
    static func parse(_ raw: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFraction.parse(raw) { return d }
        // Seven fractional digits are more than the style takes: cut to three.
        if let dot = raw.firstIndex(of: "."), let end = raw[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = raw[raw.index(after: dot)..<end].prefix(3)
            if let d = try? withFraction.parse(String(raw[..<dot]) + "." + fraction + raw[end...]) { return d }
        }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }
}

public extension JellyfinClient {
    /// How many songs the chosen music libraries hold, and how many were played this
    /// week (from the last 500 plays), for HomeVoice.
    func homeStats() async throws -> (songs: Int, week: Int) {
        let libraries = libraryScope
        var songs = 0
        for parent in libraries.isEmpty ? [nil] : libraries.map(Optional.some) {
            let response: JfItemsResponse = try await get("/Items", params: [
                "userId": currentConfig.userId, "recursive": "true", "includeItemTypes": "Audio",
                "limit": "0", "parentId": parent,
            ])
            songs += response.totalRecordCount ?? 0
        }
        let played = try await recentlyPlayed(limit: 500)
        return (songs, HomeVoice.playedThisWeek(played))
    }
}
