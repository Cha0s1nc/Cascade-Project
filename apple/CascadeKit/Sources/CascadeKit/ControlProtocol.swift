import Foundation
import Security

// The Cha0s Stream control server's wire side, byte-compatible with main.js ~263-325: parsing a
// request, the token check, and the JSON each route returns. The socket is App/Mac/ControlServer.swift.

public struct ControlRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public struct ControlResponse: Sendable, Equatable {
    public var status: Int
    public var body: String
    public init(status: Int, body: String) { self.status = status; self.body = body }

    /// The bytes on the wire. Node's `res.writeHead(404); res.end()` has no body and no content type.
    public var data: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "OK"
        let bytes = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if status != 404 { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }
}

public enum ControlParse: Sendable, Equatable {
    case incomplete
    case malformed
    case request(ControlRequest)
}

/// What the routes need from the app, read at request time.
public struct ControlContext: Sendable {
    public struct Session: Sendable, Equatable {
        public var url: String, token: String, userId: String
        public init(url: String, token: String, userId: String) { self.url = url; self.token = token; self.userId = userId }
    }
    public var version: String
    /// The live session; nil until signed in.
    public var jellyfin: Session?
    public var nowPlaying: ControlNowPlaying
    public var perform: @Sendable (String) -> Void

    public init(version: String, jellyfin: Session?, nowPlaying: ControlNowPlaying,
                perform: @escaping @Sendable (String) -> Void) {
        self.version = version; self.jellyfin = jellyfin; self.nowPlaying = nowPlaying; self.perform = perform
    }
}

/// The `/cascade/now-playing` document. Nothing played yet is `{title:null,artist:null,isPlaying:false}`.
public struct ControlNowPlaying: Sendable, Equatable {
    public var title: String?, artist: String?, album: String?, trackId: String?
    public var artItemId: String?, artImageTag: String?
    public var durationMs: Int?, positionMs: Int?
    public var isPlaying = false
    public var hasTrack: Bool

    public static let empty = ControlNowPlaying(hasTrack: false)
    public init(title: String? = nil, artist: String? = nil, album: String? = nil, trackId: String? = nil,
                artItemId: String? = nil, artImageTag: String? = nil, durationMs: Int? = nil,
                positionMs: Int? = nil, isPlaying: Bool = false, hasTrack: Bool = true) {
        self.title = title; self.artist = artist; self.album = album; self.trackId = trackId
        self.artItemId = artItemId; self.artImageTag = artImageTag; self.durationMs = durationMs
        self.positionMs = positionMs; self.isPlaying = isPlaying; self.hasTrack = hasTrack
    }

    var json: String {
        var f: [(String, String)] = [("title", controlJSONString(title)), ("artist", controlJSONString(artist)),
                                     ("isPlaying", isPlaying ? "true" : "false")]
        if hasTrack {
            f += [("album", controlJSONString(album)), ("trackId", controlJSONString(trackId)),
                  ("artItemId", controlJSONString(artItemId)), ("artImageTag", controlJSONString(artImageTag)),
                  ("durationMs", durationMs.map(String.init) ?? "null"), ("positionMs", positionMs.map(String.init) ?? "null")]
        }
        return "{" + f.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
}

/// A JSON string literal, or `null`. Hand-built so key order matches what Electron sent.
public func controlJSONString(_ s: String?) -> String {
    guard let s else { return "null" }
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out += u.value < 0x20 ? String(format: "\\u%04x", u.value) : String(u)
        }
    }
    return out + "\""
}

public enum ControlServerProtocol {
    public static let port: UInt16 = 47847
    public static let actions: Set<String> = ["playpause", "next", "prev"]
    static let maxBytes = 64 * 1024

    public static func parse(_ data: Data) -> ControlParse {
        let data = Data(data)
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxBytes ? .malformed : .incomplete
        }
        guard let head = String(data: data[0..<split.lowerBound], encoding: .utf8) else { return .malformed }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let want = Int(headers["content-length"] ?? "0") ?? 0
        guard want >= 0, want <= maxBytes else { return .malformed }
        let body = data[split.upperBound...]
        if body.count < want { return .incomplete }
        return .request(ControlRequest(method: String(start[0]), path: String(start[1]), headers: headers,
                                       body: Data(body.prefix(want))))
    }

    /// The token is checked before anything else, so an unauthorized request learns nothing about routes.
    public static func route(_ req: ControlRequest, token: String, context: ControlContext) -> ControlResponse {
        guard req.headers["x-cascade-token"] == token else {
            return ControlResponse(status: 401, body: #"{"ok":false,"error":"Unauthorized"}"#)
        }
        switch (req.method, req.path) {
        case ("POST", "/cascade/control"):
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let action = obj["action"] as? String, actions.contains(action) else {
                return ControlResponse(status: 400, body: #"{"ok":false,"error":"Bad request"}"#)
            }
            context.perform(action)
            return ControlResponse(status: 200, body: #"{"ok":true}"#)
        case ("GET", "/cascade/status"):
            return ControlResponse(status: 200, body: #"{"ok":true,"app":"Cascade","version":"# + controlJSONString(context.version) + "}")
        case ("GET", "/cascade/jellyfin"):
            guard let j = context.jellyfin else {
                return ControlResponse(status: 404, body: #"{"ok":false,"error":"Not connected to Jellyfin"}"#)
            }
            return ControlResponse(status: 200, body: #"{"ok":true,"url":"# + controlJSONString(j.url) + #","token":"# + controlJSONString(j.token) + #","userId":"# + controlJSONString(j.userId) + "}")
        case ("GET", "/cascade/now-playing"):
            return ControlResponse(status: 200, body: context.nowPlaying.json)
        default:
            return ControlResponse(status: 404, body: "")
        }
    }
}

/// `~/.cascade-control-token`: shared with Cha0s Stream and the Electron build, so an existing
/// file is never rewritten, even an invalid one (nil, and the server stays off).
public enum ControlToken {
    public static var defaultPath: String { NSHomeDirectory() + "/.cascade-control-token" }

    public static func isValid(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    public static func load(path: String = defaultPath) -> String? {
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let t = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            return isValid(t) ? t : nil
        }
        guard !FileManager.default.fileExists(atPath: path) else { return nil }
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else { return nil }
        let token = raw.map { String(format: "%02x", $0) }.joined()
        // O_EXCL: if the Electron build creates it between the check and here, theirs wins.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd < 0 { return load(path: path) }
        defer { close(fd) }
        let bytes = Array(token.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { return nil }
        return token
    }
}
