import Foundation

/// Longest a server error body is allowed to become once turned into an error
/// message. Past this it is truncated rather than shown whole.
private let maxErrorMessageLength = 300

public struct JellyfinError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
}

/// Turn a failed response into a short, readable message.
///
/// Jellyfin's own error bodies are short plain text and worth showing as-is. A
/// reverse proxy in front of a dead server answers instead with a whole HTML
/// error page, and dumping kilobytes of markup into an alert fills the screen
/// with red. Detect that by content-type or a leading `<` and fall back to the
/// status line.
func errorMessage(response: HTTPURLResponse, body: Data) -> String {
    let status = "\(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
    let text = (String(data: body, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return status }

    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
    if contentType.contains("html") || text.hasPrefix("<") { return status }

    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > maxErrorMessageLength
        ? String(collapsed.prefix(maxErrorMessageLength)) + "\u{2026}"
        : collapsed
}

/// Identifies this client to Jellyfin.
public func authHeader(appVersion: String, deviceId: String) -> String {
    "MediaBrowser Client=\"Cascade\", Device=\"Cascade\", DeviceId=\"\(deviceId)\", Version=\"\(appVersion)\""
}

/// Authenticate against a server. Standalone rather than a client method
/// because it runs before there is any config to construct a client with.
public func authenticate(serverUrl: String, username: String, password: String,
                         appVersion: String, deviceId: String,
                         session: URLSession = .shared) async throws -> JfAuthResult {
    let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
    guard let url = URL(string: "\(base)/Users/AuthenticateByName") else {
        throw JellyfinError(status: 0, message: "Not a valid server address")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(authHeader(appVersion: appVersion, deviceId: deviceId),
                     forHTTPHeaderField: "X-Emby-Authorization")
    request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])  // literal keys, no strategy needed

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw JellyfinError(status: 0, message: "No HTTP response from \(base)")
    }
    guard (200..<300).contains(http.statusCode) else {
        throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: data))
    }
    return try JSON.decoder.decode(JfAuthResult.self, from: data)
}

public actor JellyfinClient {
    private var config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Sign-in replaces the whole config, so callers hold the client and swap
    /// what is inside it rather than rebuilding it and risking a stale copy
    /// still being used somewhere.
    public func update(config: ServerConfig) { self.config = config }
    public var currentConfig: ServerConfig { config }

    private func makeURL(_ path: String, _ params: [String: String?]) throws -> URL {
        guard var components = URLComponents(string: config.url + path) else {
            throw JellyfinError(status: 0, message: "Bad URL for \(path)")
        }
        // Skipping nil rather than letting it stringify to the literal
        // "nil", which is never what a caller means.
        // Sorted so the same params always build the same URL, which is what
        // makes these testable without matching on a set.
        let pairs = params.sorted { $0.key < $1.key }.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        if !pairs.isEmpty { components.queryItems = pairs }
        guard let url = components.url else {
            throw JellyfinError(status: 0, message: "Bad URL for \(path)")
        }
        return url
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue(config.token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(status: 0, message: "No HTTP response")
        }
        // Every write path checks this. On desktop, five separate writes
        // reported success on an HTTP 403 because nothing looked at the status,
        // and one mutated local state anyway, so a refused delete looked
        // identical to a successful one.
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError(status: http.statusCode, message: errorMessage(response: http, body: data))
        }
        return data
    }

    public func get<T: Decodable>(_ path: String, params: [String: String?] = [:],
                                  as type: T.Type = T.self) async throws -> T {
        let data = try await send(URLRequest(url: try makeURL(path, params)))
        return try JSON.decoder.decode(T.self, from: data)
    }

    /// POST with a JSON body, decoding the reply.
    public func post<Body: Encodable, T: Decodable>(_ path: String, body: Body,
                                                    params: [String: String?] = [:],
                                                    as type: T.Type = T.self) async throws -> T {
        let data = try await postRaw(path, body: body, params: params)
        return try JSON.decoder.decode(T.self, from: data)
    }

    /// POST where the reply body is not wanted. Still throws on a bad status,
    /// which is the whole point.
    @discardableResult
    public func postRaw<Body: Encodable>(_ path: String, body: Body?,
                                         params: [String: String?] = [:]) async throws -> Data {
        var request = URLRequest(url: try makeURL(path, params))
        request.httpMethod = "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSON.encoder.encode(body)
        }
        return try await send(request)
    }

    @discardableResult
    public func delete(_ path: String, params: [String: String?] = [:]) async throws -> Data {
        var request = URLRequest(url: try makeURL(path, params))
        request.httpMethod = "DELETE"
        return try await send(request)
    }

    /// Primary image URL for an item. No tag means no art, so no URL.
    public func artUrl(itemId: String, tag: String?) -> URL? {
        guard tag != nil else { return nil }
        return imageUrl(itemId: itemId)
    }

    public func imageUrl(itemId: String, size: Int = 600) -> URL? {
        URL(string: "\(config.url)/Items/\(itemId)/Images/Primary"
            + "?fillHeight=\(size)&fillWidth=\(size)&quality=90&api_key=\(config.token)")
    }
}

/// An empty JSON body, for POSTs that need one but carry nothing.
public struct EmptyBody: Encodable, Sendable {
    public init() {}
}
