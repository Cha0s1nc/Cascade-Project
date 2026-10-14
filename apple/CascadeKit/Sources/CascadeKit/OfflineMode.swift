import Foundation

// Offline Mode's one state (docs/offline-mode-plan.md, section 4), pure so the
// rules are tested here; AppState holds the value and acts on changes. The
// same rules as the desktop's src/core/offline-mode.ts.
//
// - online: the server answers.
// - manual: the Settings switch is on. Nothing is sent to the server, and it
//   stays on until the person turns it off, whatever the network does.
// - unreachable: the server stopped answering. Probed again on a backoff and
//   on a network change; left by itself when it answers.

public enum OfflineState: String, Sendable, Equatable {
    case online, manual, unreachable
}

public enum OfflineEvent: Sendable, Equatable {
    /// The Settings switch, turned on or off.
    case setSwitch(Bool)
    /// A request or probe found no server.
    case unreachable
    /// A request or probe was answered.
    case reachable
}

public enum OfflineMode {
    /// The state after an event. A manual switch outranks what the network
    /// says; turning it off goes back online, and the next request finds out
    /// whether the server is really there.
    public static func next(_ state: OfflineState, _ event: OfflineEvent) -> OfflineState {
        switch event {
        case .setSwitch(let on): return on ? .manual : state == .manual ? .online : state
        case .unreachable: return state == .online ? .unreachable : state
        case .reachable: return state == .unreachable ? .online : state
        }
    }

    public static func isOffline(_ state: OfflineState) -> Bool { state != .online }

    /// First probe 30 s after the drop, doubling to five minutes. `attempt`
    /// counts from 0.
    public static func probeDelay(attempt: Int) -> TimeInterval {
        let n = min(max(attempt, 0), 10)
        return min(30 * pow(2, Double(n)), 300)
    }

    public enum FailureKind: Sendable, Equatable {
        /// No answer, or a reverse proxy saying the server behind it is down.
        case unreachable
        /// The session expired: sign in again. Never Offline Mode.
        case auth
        /// The server answered with a failure: the request's problem, not the
        /// connection's.
        case error
    }

    /// What a failed request says about the server. Nil or 0 is no answer.
    public static func failureKind(status: Int?) -> FailureKind {
        guard let status, status != 0 else { return .unreachable }
        switch status {
        case 401, 403: return .auth
        case 502, 503, 504: return .unreachable
        default: return .error
        }
    }

    /// Whether a URLSession failure means no server rather than a request
    /// someone stopped: a cancelled request says nothing about the network.
    public static func isNoAnswer(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return e.code != .cancelled && e.code != .badURL && e.code != .unsupportedURL
    }

    /// Update checks wait while offline, and one runs as soon as the app is
    /// back online.
    public static func checksUpdates(_ state: OfflineState) -> Bool { state == .online }
    public static func updateCheckDue(from before: OfflineState, to after: OfflineState) -> Bool {
        before != .online && after == .online
    }

    // MARK: - The swap

    /// Answers a request JellyfinClient was about to send, from the catalog.
    /// A GET is the engine's answer, as the server's JSON would be; any other
    /// method is refused, since nothing may reach the server. `base` is the
    /// server address the client builds URLs from, whose own path (a reverse
    /// proxy's /jellyfin) is not part of the route.
    public static func answer(_ request: URLRequest, base: String, engine: OfflineQuery.Engine) throws -> Data {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET", let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw OfflineError() }
        var path = parts.path
        let prefix = URLComponents(string: base)?.path ?? ""
        if !prefix.isEmpty, prefix != "/", path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        if prefix.hasSuffix("/"), !path.hasPrefix("/") { path = "/" + path }
        var params: [String: String?] = [:]
        for item in parts.queryItems ?? [] { params[item.name] = item.value }
        let reply = engine.answer(path: path, params: params)
        guard reply.status == 200 else {
            throw JellyfinError(status: reply.status, message: "That is not in your downloads.")
        }
        return reply.body
    }
}

/// Thrown instead of sending anything while Offline Mode is on: a write, a
/// lyrics source, the updater. Screens show its message.
public struct OfflineError: LocalizedError, Sendable, Equatable {
    public init() {}
    public var errorDescription: String? { "Not available offline." }
}

/// Whether Offline Mode is on, for the few calls that do not go through
/// JellyfinClient: third-party lyrics, iTunes art, the Waterfall relay, the
/// Mac's updater. AppState sets it; they check it before sending.
public final class OfflineGate: @unchecked Sendable {
    public static let shared = OfflineGate()
    private let lock = NSLock()
    private var offline = false

    public var isOffline: Bool {
        lock.lock(); defer { lock.unlock() }
        return offline
    }

    public func set(_ state: OfflineState) {
        lock.lock(); defer { lock.unlock() }
        offline = OfflineMode.isOffline(state)
    }

    /// Throws OfflineError while Offline Mode is on.
    public func check() throws {
        if isOffline { throw OfflineError() }
    }
}
