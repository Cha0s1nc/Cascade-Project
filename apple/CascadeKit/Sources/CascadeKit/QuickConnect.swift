import Foundation

// QuickConnect: sign in by approving a short code on a device that is already
// signed in (Jellyfin web, another app), instead of typing a password. On tvOS
// it is the only sane way in, and it means no password ever touches this app.
//
// Ported from the desktop's src/core/jellyfin.ts and checked against the
// server's own spec (/api-docs/openapi.json, Jellyfin 10.11.11):
//   GET  /QuickConnect/Enabled                -> Bool
//   POST /QuickConnect/Initiate               -> QuickConnectResult (needs the auth header)
//   GET  /QuickConnect/Connect?secret=        -> QuickConnectResult, 404 once expired
//   POST /Users/AuthenticateWithQuickConnect  {Secret} -> AuthenticationResult

/// What the server hands back when a request is started, and on each poll.
public struct QuickConnectState: Decodable, Sendable, Equatable {
    public var secret: String
    /// The code the user types on the other device.
    public var code: String
    public var authenticated: Bool?

    public init(secret: String, code: String, authenticated: Bool? = nil) {
        self.secret = secret
        self.code = code
        self.authenticated = authenticated
    }
}

public enum QuickConnect {
    /// How often to ask whether the code has been approved.
    public static let pollInterval: Duration = .seconds(2)
    /// Give up after this long, so a forgotten sign-in does not poll forever.
    public static let timeout: Duration = .seconds(300)

    static func base(_ serverUrl: String) -> String {
        serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
    }

    /// An empty or scheme-less address would otherwise become a relative URL
    /// that fails later with a far less useful message.
    static func url(_ serverUrl: String, _ path: String) throws -> URL {
        guard let url = URL(string: base(serverUrl) + path),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
            throw JellyfinError(status: 0, message: "Not a valid server address")
        }
        return url
    }

    /// The device id matters on the two authenticated calls: Jellyfin ties the
    /// pending request to it, and it is what the resulting token is bound to.
    static func initiateRequest(serverUrl: String, appVersion: String, deviceId: String) throws -> URLRequest {
        var r = URLRequest(url: try url(serverUrl, "/QuickConnect/Initiate"))
        r.httpMethod = "POST"
        r.setValue(authHeader(appVersion: appVersion, deviceId: deviceId), forHTTPHeaderField: "X-Emby-Authorization")
        return r
    }

    static func connectRequest(serverUrl: String, secret: String) throws -> URLRequest {
        guard var c = URLComponents(url: try url(serverUrl, "/QuickConnect/Connect"), resolvingAgainstBaseURL: false) else {
            throw JellyfinError(status: 0, message: "Not a valid server address")
        }
        c.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let u = c.url else { throw JellyfinError(status: 0, message: "Not a valid server address") }
        return URLRequest(url: u)
    }

    static func authenticateRequest(serverUrl: String, secret: String, appVersion: String, deviceId: String) throws -> URLRequest {
        var r = URLRequest(url: try url(serverUrl, "/Users/AuthenticateWithQuickConnect"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(authHeader(appVersion: appVersion, deviceId: deviceId), forHTTPHeaderField: "X-Emby-Authorization")
        r.httpBody = try JSONEncoder().encode(["Secret": secret])   // literal key, no strategy needed
        return r
    }

    /// Whether the server offers it. Never throws: a server that errors here
    /// simply does not, and the password form is still there.
    public static func isEnabled(serverUrl: String, session: URLSession = .shared) async -> Bool {
        guard let u = try? url(serverUrl, "/QuickConnect/Enabled"),
              let (data, response) = try? await session.data(from: u),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) == true
    }

    /// Start a request and get the code to show the user.
    public static func initiate(serverUrl: String, appVersion: String, deviceId: String,
                                session: URLSession = .shared) async throws -> QuickConnectState {
        let data = try await send(initiateRequest(serverUrl: serverUrl, appVersion: appVersion, deviceId: deviceId), session)
        return try JSON.decoder.decode(QuickConnectState.self, from: data)
    }

    /// True once approved on the other device. A 404 means the request expired
    /// or was cancelled server-side, and a network blip is just a missed poll:
    /// both read as "not yet", and `timeout` is what ends the wait.
    public static func isApproved(serverUrl: String, secret: String, session: URLSession = .shared) async -> Bool {
        guard let request = try? connectRequest(serverUrl: serverUrl, secret: secret),
              let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let state = try? JSON.decoder.decode(QuickConnectState.self, from: data)
        else { return false }
        return state.authenticated == true
    }

    /// Trade an approved secret for a real access token.
    public static func authenticate(serverUrl: String, secret: String, appVersion: String, deviceId: String,
                                    session: URLSession = .shared) async throws -> JfAuthResult {
        let data = try await send(authenticateRequest(serverUrl: serverUrl, secret: secret,
                                                      appVersion: appVersion, deviceId: deviceId), session)
        return try JSON.decoder.decode(JfAuthResult.self, from: data)
    }

    private static func send(_ request: URLRequest, _ session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: data))
        }
        return data
    }
}
