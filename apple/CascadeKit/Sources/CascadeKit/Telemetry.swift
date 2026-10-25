import Foundation

/// Opt-in usage telemetry, the native side of src/core/telemetry.ts: one ping
/// a day with a random install id, the app version, edition and device kind,
/// and how many songs played since the last ping that landed.
///
/// DORMANT while `url` is nil: `optedIn` is false, nothing is counted, stored
/// or sent, and the wizard step is filtered out. The switch-on checklist is in
/// src/core/telemetry.ts and telemetry/NOTES.md.
public enum Telemetry {
    public static let url: URL? = nil

    public static var available: Bool { url != nil }

    static let interval: TimeInterval = 24 * 60 * 60
    /// TELEMETRY_MAX_SONGS in src/core/telemetry.ts; the Worker rejects more.
    static let maxSongs = 5000

    static let optInKey = "cascade.telemetryOptIn"
    static let installIdKey = "cascade.telemetryInstallId"
    static let songsKey = "cascade.telemetrySongs"
    static let lastSentKey = "cascade.telemetryLastSent"

    public static func optedIn(_ defaults: UserDefaults = .standard) -> Bool {
        available && defaults.bool(forKey: optInKey)
    }

    /// The install id is its own random UUID, never the Jellyfin DeviceId,
    /// which the server already knows. Opting out forgets the install.
    public static func setOptIn(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: optInKey)
        if on {
            if defaults.string(forKey: installIdKey) == nil {
                defaults.set(UUID().uuidString.lowercased(), forKey: installIdKey)
            }
        } else {
            for k in [installIdKey, songsKey, lastSentKey] { defaults.removeObject(forKey: k) }
        }
    }

    public static func countSong(_ defaults: UserDefaults = .standard) {
        guard optedIn(defaults) else { return }
        defaults.set(defaults.integer(forKey: songsKey) + 1, forKey: songsKey)
    }

    /// Never sent counts as due, so opting in is counted that day.
    static func due(lastSent: Double, now: Date) -> Bool {
        lastSent <= 0 || now.timeIntervalSince1970 - lastSent >= interval
    }

    struct Ping: Encodable, Equatable {
        let installId: String
        let version: String
        let edition: String
        let device: String
        let songs: Int
    }

    static func ping(installId: String, songs: Int) -> Ping {
        Ping(installId: installId, version: cascadeAppVersion, edition: cascadeEdition,
             device: cascadeDeviceName, songs: min(max(songs, 0), maxSongs))
    }

    /// Sends if opted in and a day has passed. A failure is simply tried on a
    /// later call; only what was sent comes off the count.
    public static func sendIfDue(session: URLSession = .shared) async {
        let defaults = UserDefaults.standard
        guard optedIn(defaults), let url,
              due(lastSent: defaults.double(forKey: lastSentKey), now: Date()),
              let installId = defaults.string(forKey: installIdKey) else { return }
        let ping = ping(installId: installId, songs: defaults.integer(forKey: songsKey))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(ping)
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              optedIn(defaults) else { return }
        defaults.set(max(0, defaults.integer(forKey: songsKey) - ping.songs), forKey: songsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastSentKey)
    }
}
