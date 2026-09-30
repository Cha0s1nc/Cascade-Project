import Foundation
@testable import CascadeKit

// Shared plumbing for the tests that talk to a real server.
//
// One sign-in for the whole run, not one per test. Jellyfin ties a token to a
// (user, device) pair, so several tests authenticating with the same device id
// in parallel revoke each other's tokens and the losers see a 401 that has
// nothing to do with what they were testing. That is the same collision the
// deviceId comment in ServerConfig warns about, met from the other side.

struct LiveCredentials {
    let server: String, user: String, pass: String

    init?() {
        let e = ProcessInfo.processInfo.environment
        guard let s = e["CASCADE_SERVER"], let u = e["CASCADE_USER"], let p = e["CASCADE_PASS"] else { return nil }
        server = s; user = u; pass = p
    }
}

let liveCredentials = LiveCredentials()

/// Caches the signed-in client so concurrent tests share one session.
actor LiveSession {
    static let shared = LiveSession()

    /// The sign-in itself, not its result. An actor releases its lock at every
    /// await, so caching the RESULT is not enough: several callers all get past
    /// an `if cached == nil` check before the first one finishes authenticating,
    /// and they all sign in. With one device id that means each sign-in revokes
    /// the last, and whichever client kept an older token starts seeing 401s on
    /// requests that have nothing wrong with them.
    ///
    /// Storing the Task before the first await makes later callers await the
    /// same sign-in instead of starting their own.
    private var signIn: Task<(JellyfinClient, ServerConfig), Error>?

    func connect() async throws -> (JellyfinClient, ServerConfig) {
        if let signIn { return try await signIn.value }
        let task = Task { try await Self.authenticateOnce() }
        signIn = task
        return try await task.value
    }

    private static func authenticateOnce() async throws -> (JellyfinClient, ServerConfig) {
        let credentials = liveCredentials!
        let deviceId = "cascade-swift-tests"
        let auth = try await authenticate(serverUrl: credentials.server, username: credentials.user,
                                          password: credentials.pass, appVersion: "0.1.0",
                                          deviceId: deviceId)
        let config = ServerConfig(url: credentials.server, token: auth.accessToken,
                                  userId: auth.user.id, deviceId: deviceId)
        return (JellyfinClient(config: config), config)
    }
}
