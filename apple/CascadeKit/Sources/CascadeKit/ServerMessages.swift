import Foundation

/// What a Jellyfin server says to people outside of playback, as the desktop's
/// src/core/server-messages.ts reads it: a message an admin sends a session
/// from the dashboard (the DisplayMessage general command, over the socket),
/// and the login disclaimer set in Branding, shown on the sign-in screen.
/// Both are text from the server, shown as plain text only.
public struct ServerMessage: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let header: String
    public let text: String
    /// How long to show it, when the sender set one; otherwise until closed.
    public let timeout: Double?

    public static func == (a: ServerMessage, b: ServerMessage) -> Bool {
        a.header == b.header && a.text == b.text && a.timeout == b.timeout
    }

    public init(header: String, text: String, timeout: Double?) {
        (self.header, self.text, self.timeout) = (header, text, timeout)
    }

    /// A DisplayMessage command's arguments (strings, as every general
    /// command's are), or nil when there is nothing to show.
    public static func parse(_ args: [String: Any]) -> ServerMessage? {
        let header = clean(args["Header"], max: 120), text = clean(args["Text"], max: 2000)
        guard !header.isEmpty || !text.isEmpty else { return nil }
        let ms = (args["TimeoutMs"] as? String).flatMap(Double.init) ?? (args["TimeoutMs"] as? Double)
        let timeout = ms.flatMap { $0.isFinite && $0 > 0 ? min($0, 600_000) / 1000 : nil }
        return ServerMessage(header: header.isEmpty ? "Message from your server" : header, text: text, timeout: timeout)
    }

    static func clean(_ v: Any?, max: Int) -> String {
        guard let s = v as? String else { return "" }
        let kept = s.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max).description
    }

    /// The Branding LoginDisclaimer as plain text. Jellyfin allows HTML there;
    /// line breaks are kept, tags dropped, the common entities decoded.
    public static func loginDisclaimerText(_ raw: String?) -> String {
        guard var s = raw else { return "" }
        s = s.replacingOccurrences(of: #"<\s*br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</\s*(p|div|li|h[1-6])\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        let lines = s.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(2000).description
    }

    private static func decodeEntities(_ s: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var out = "", rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 10 {
                let name = String(after[..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") { decoded = UInt32(name.dropFirst(2), radix: 16).flatMap { $0 > 31 ? Unicode.Scalar($0).map(String.init) : nil } }
                else if name.hasPrefix("#") { decoded = UInt32(name.dropFirst()).flatMap { $0 > 31 ? Unicode.Scalar($0).map(String.init) : nil } }
                else { decoded = named[name.lowercased()] }
                if let decoded { out += decoded; rest = after[after.index(after: semi)...]; continue }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    /// The server's login disclaimer, or "" for none or no answer.
    /// /Branding/Configuration needs no sign-in, which is the point.
    public static func fetchLoginDisclaimer(serverURL: String) async -> String {
        guard let url = URL(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/Branding/Configuration"),
              url.scheme == "http" || url.scheme == "https" else { return "" }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "GET"
        guard let (data, response) = try? await ProxyConnection.shared.session(for: url).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return loginDisclaimerText(object["LoginDisclaimer"] as? String)
    }
}
