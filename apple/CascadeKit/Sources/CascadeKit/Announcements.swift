import Foundation

/// Announcements, as the desktop's src/core/announcements.ts reads them: the
/// Cascade project's own feed (shared/announcements.json, uploaded to R2 by
/// .github/workflows/announcements.yml), a Cascade Server plugin's posts (GET
/// /CascadeServer/Announcements, capability "announcements"), and messages an
/// admin sends this session from Jellyfin's dashboard, which are kept here too.
///
/// Every shipped app reads the feed forever, so its shape only grows:
///   { id, date: "YYYY-MM-DD", title, body?, link?: "https://...",
///     platforms?: ["desktop" | "mac" | "ios" | "tvos"],
///     minVersion?, maxVersion?, expires?: "YYYY-MM-DD" }
/// Missing platforms means every app. The version window is inclusive. An entry
/// shows through the whole of its expires day (UTC). An entry that does not
/// parse is dropped, not the whole file. Text only.
///
/// `kind` comes from where an entry was read, never from its contents, so a
/// server cannot dress its posts up as the project's: the inbox draws an
/// Official badge for `.official` and a Server badge for `.server`.
public struct Announcement: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case official, server }

    public let id: String
    public let date: String
    public let title: String
    public let body: String
    public let link: URL?
    public let kind: Kind
    /// Who it is from, for a server's entry: the server's name.
    public let source: String?

    public init(id: String, date: String, title: String, body: String, link: URL?, kind: Kind, source: String?) {
        (self.id, self.date, self.title, self.body, self.link, self.kind, self.source) = (id, date, title, body, link, kind, source)
    }
}

public enum Announcements {
    public static let url = URL(string: "https://plugins.chaosinc.xyz/announcements.json")!

    /// This app's name in the feed's `platforms`.
    public static var platform: String {
        #if os(tvOS)
        "tvos"
        #elseif os(macOS)
        "mac"
        #else
        "ios"
        #endif
    }

    /// This build's version, for the feed's version window.
    public static var appVersion: String { cascadeAppVersion }

    static let maxEntries = 50

    private static func isDate(_ v: Any?) -> String? {
        guard let s = v as? String, s.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        return s
    }

    private static func utcDay(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The entries for this app and version that have not expired, newest first.
    public static func parse(_ raw: Any?, platform: String = platform, version: String = appVersion,
                             now: Date = Date(), kind: Announcement.Kind = .official) -> [Announcement] {
        guard let list = raw as? [Any] else { return [] }
        let today = utcDay(now)
        var out: [Announcement] = [], ids = Set<String>()
        for e in list {
            guard let a = e as? [String: Any] else { continue }
            let id = ServerMessage.clean(a["id"], max: 80), title = ServerMessage.clean(a["title"], max: 120)
            guard !id.isEmpty, !title.isEmpty, let date = isDate(a["date"]), !ids.contains(id) else { continue }
            if let platforms = a["platforms"] as? [Any], !platforms.contains(where: { $0 as? String == platform }) { continue }
            if let min = a["minVersion"] as? String, UpdateRelease.isNewerVersion(min, than: version) { continue }
            if let max = a["maxVersion"] as? String, UpdateRelease.isNewerVersion(version, than: max) { continue }
            if let expires = isDate(a["expires"]), expires < today { continue }
            ids.insert(id)
            let link = (a["link"] as? String).flatMap { s in
                s.wholeMatch(of: /(?i)https:\/\/\S+/) != nil ? URL(string: s) : nil
            }
            let source = ServerMessage.clean(a["source"], max: 120)
            out.append(Announcement(id: id, date: date, title: title, body: ServerMessage.clean(a["body"], max: 4000),
                                    link: link, kind: kind, source: source.isEmpty ? nil : source))
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(maxEntries))
    }

    /// A Cascade Server plugin's posts, ids kept apart per server and labeled
    /// with its name, or none when the answer is not shaped like one.
    public static func parseServer(_ raw: Any?, platform: String = platform, version: String = appVersion,
                                   now: Date = Date()) -> [Announcement] {
        let r = raw as? [String: Any] ?? [:]
        let server = r["server"] as? [String: Any] ?? [:]
        let serverId = ServerMessage.clean(server["id"], max: 64)
        guard !serverId.isEmpty else { return [] }
        let name = ServerMessage.clean(server["name"], max: 120)
        return parse(r["items"], platform: platform, version: version, now: now, kind: .server).map {
            Announcement(id: "server:\(serverId):\($0.id)", date: $0.date, title: $0.title, body: $0.body,
                         link: $0.link, kind: .server, source: name.isEmpty ? "Your server" : name)
        }
    }

    /// The stored dashboard messages with this one first, as UserDefaults keeps
    /// them (read back with parse(_:kind: .server)). The oldest fall off.
    public static func addMessage(_ stored: Any?, _ message: ServerMessage, serverName: String, now: Date = Date()) -> [[String: String]] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let name = ServerMessage.clean(serverName, max: 120)
        let entry = ["id": "message:\(String(Int(now.timeIntervalSince1970 * 1000), radix: 36))",
                     "date": String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
                     "title": message.header, "body": message.text, "source": name.isEmpty ? "Your server" : name]
        return Array(([entry] + (stored as? [[String: String]] ?? [])).prefix(maxEntries))
    }

    /// What the inbox shows, and how many of those are new since it was last opened.
    public static func inbox(_ list: [Announcement], dismissed: [String], seen: [String]) -> (items: [Announcement], unseen: Int) {
        let gone = Set(dismissed), old = Set(seen)
        let items = list.filter { !gone.contains($0.id) }
        return (items, items.filter { !old.contains($0.id) }.count)
    }

    /// The project's feed as JSON: [] when it is not uploaded yet, nil when it
    /// could not be read. The caller checks Offline Mode first.
    public static func fetch(session: URLSession = .shared) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("cascade", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        // Not uploaded yet: nothing to announce, not a failure.
        if status == 404 { return [Any]() }
        guard status == 200, data.count <= 512 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
