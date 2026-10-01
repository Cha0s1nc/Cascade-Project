import Foundation

// Extra HTTP headers for a Jellyfin server behind a reverse proxy (Cloudflare
// Access service tokens, Authelia). The proxy refuses any request without the
// header, so without this the app cannot even reach the sign-in. The pure part,
// ported from the desktop's src/core/custom-headers.ts with its tests. What
// applies them to URLSession and AVURLAsset is ProxyConnection.swift.

public struct ProxyHeader: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum ProxyHeaders {
    /// More than this is a typo or a paste accident, not a proxy's requirements.
    public static let maxCount = 16
    public static let maxValueLength = 4096

    /// Names a person may not set: they would break the request framing or
    /// replace Cascade's own sign-in. Lowercase. X-Emby-Authorization is
    /// Jellyfin's older spelling of Authorization.
    public static let blockedNames: Set<String> = [
        "authorization", "x-emby-authorization", "host", "content-length", "transfer-encoding",
    ]

    // RFC 9110 token characters.
    private static let tokenCharacters = CharacterSet(charactersIn:
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Why `name` cannot be a header name, or nil when it can.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "A header needs a name." }
        if name.unicodeScalars.contains(where: { !tokenCharacters.contains($0) }) {
            return "\"\(name.prefix(40))\" is not a valid header name."
        }
        if blockedNames.contains(name.lowercased()) { return "\(name) cannot be overridden." }
        return nil
    }

    /// Why `value` cannot be a header value, or nil when it can.
    public static func valueProblem(_ value: String) -> String? {
        if value.isEmpty { return "A header needs a value." }
        if value.count > maxValueLength { return "That header value is too long." }
        // A line break would let a value smuggle in a second header.
        let bad = value.unicodeScalars.contains { s in
            (s.value < 0x20 && s.value != 0x09) || s.value == 0x7f
        }
        return bad ? "A header value cannot contain control characters." : nil
    }

    /// The problem with adding `header` to `existing`, or nil when it fits.
    public static func problem(adding header: ProxyHeader, to existing: [ProxyHeader]) -> String? {
        if let p = nameProblem(header.name) ?? valueProblem(header.value) { return p }
        if existing.contains(where: { $0.name.lowercased() == header.name.lowercased() }) {
            return "\(header.name) is already listed."
        }
        if existing.count >= maxCount { return "At most \(maxCount) headers." }
        return nil
    }

    /// Headers from storage, which is untrusted: anything invalid, duplicated or
    /// past the cap is dropped, never repaired.
    public static func sanitized(_ list: [ProxyHeader]) -> [ProxyHeader] {
        var out: [ProxyHeader] = []
        for h in list where problem(adding: h, to: out) == nil { out.append(h) }
        return out
    }

    /// `Name: Value` lines, one per header, for a person to read or paste.
    public static func format(_ headers: [ProxyHeader]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// The inverse of `format`. Blank lines and lines starting with # are
    /// skipped. Every problem comes back with its line, not just the first.
    public static func parse(_ text: String) -> (headers: [ProxyHeader], errors: [String]) {
        var headers: [ProxyHeader] = []
        var errors: [String] = []
        // components(separatedBy: .newlines), not split(separator: "\n"): Swift reads "\r\n" as one Character, so a Windows paste would not split.
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { errors.append("Line \(i + 1): use Name: Value."); continue }
            let header = ProxyHeader(
                name: line[..<colon].trimmingCharacters(in: .whitespaces),
                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if let p = problem(adding: header, to: headers) { errors.append("Line \(i + 1): \(p)"); continue }
            headers.append(header)
        }
        return (headers, errors)
    }

    /// scheme://host:port, the default port left off, and a WebSocket counted
    /// as the HTTP it upgrades from (the remote-control socket goes to the same
    /// server). Nil for anything that is not http, https, ws or wss.
    public static func origin(of url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        let http: String
        switch scheme {
        case "http", "ws": http = "http"
        case "https", "wss": http = "https"
        default: return nil
        }
        var port = ""
        if let p = parts.port, !((http == "http" && p == 80) || (http == "https" && p == 443)) { port = ":\(p)" }
        return "\(http)://\(host)\(port)"
    }

    /// Whether two URLs name the same host, whatever the scheme or port: an
    /// http to https upgrade on the same host is not leaving the server.
    public static func sameHost(_ a: URL, _ b: URL) -> Bool {
        guard let x = URLComponents(url: a, resolvingAgainstBaseURL: false)?.host?.lowercased(), !x.isEmpty,
              let y = URLComponents(url: b, resolvingAgainstBaseURL: false)?.host?.lowercased() else { return false }
        return x == y
    }

    /// The headers to add to a request to `url`: all of them when it goes to
    /// the Jellyfin server's own origin, none for any other host (lyrics
    /// providers, the Waterfall relay). A server path does not matter: the
    /// proxy answers for the whole origin.
    public static func headers(for url: URL, server: URL?, from headers: [ProxyHeader]) -> [ProxyHeader] {
        guard !headers.isEmpty, let server, let target = origin(of: url), let mine = origin(of: server) else { return [] }
        return target == mine ? headers : []
    }
}
