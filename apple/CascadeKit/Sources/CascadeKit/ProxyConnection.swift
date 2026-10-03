import Foundation
import AVFoundation
import Security

// Applies the reverse proxy headers and the client certificate to everything
// that talks to the Jellyfin server: the API sessions, artwork, the socket, the
// background download session and every AVURLAsset (music, video, preload).
// AVPlayer does its own networking, so URLSession configuration never reaches
// it: missing the asset path would make sign-in work and playback fail.
//
// Headers only ever go to the server's own origin (`session(for:)`,
// `assetOptions(for:)`), never to the lyric providers or the Waterfall relay.

public final class ProxyConnection: @unchecked Sendable {
    public static let shared = ProxyConnection()

    private let lock = NSLock()
    private var server: URL?
    private var headers: [ProxyHeader] = []
    private var built: URLSession?

    public init() {}

    /// The server the headers are for, set before the first request: a proxy
    /// that wants a header refuses the sign-in itself without it.
    public func setServer(_ address: String?) {
        let url = address.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        lock.lock(); defer { lock.unlock() }
        server = url
    }

    /// Replaces the headers (sanitized: storage and the UI are not trusted to
    /// have checked them) and drops the session, so the next use builds one
    /// with them.
    public func setHeaders(_ list: [ProxyHeader]) {
        let clean = ProxyHeaders.sanitized(list)
        lock.lock(); defer { lock.unlock() }
        headers = clean
        built?.finishTasksAndInvalidate()
        built = nil
    }

    public var currentHeaders: [ProxyHeader] {
        lock.lock(); defer { lock.unlock() }
        return headers
    }

    /// The session for Jellyfin API calls: the headers as session defaults, the
    /// client certificate, and no redirects off the server's host. Fetch it at
    /// the time of use, never keep it: a header edit replaces it.
    public var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let built { return built }
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.shared   // covers stay cached, as with .shared
        if !headers.isEmpty {
            config.httpAdditionalHeaders = Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        let made = URLSession(configuration: config, delegate: ProxySessionDelegate(self), delegateQueue: nil)
        built = made
        return made
    }

    /// The right session for `url`: this one for the server, the shared one
    /// for anything else, so another host never sees the headers.
    public func session(for url: URL) -> URLSession {
        isServer(url) ? session : .shared
    }

    func isServer(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let server, let a = ProxyHeaders.origin(of: url), let b = ProxyHeaders.origin(of: server) else { return false }
        return a == b
    }

    func isServer(_ space: URLProtectionSpace) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let server, let mine = ProxyHeaders.origin(of: server),
              let theirs = ProxyHeaders.origin(host: space.host, port: space.port, protocol: space.protocol) else { return false }
        return mine == theirs
    }

    /// The answer to a server's request for a client certificate: the identity
    /// the person imported, for the server's own origin only; every other
    /// challenge (server trust included) gets the default handling.
    func respond(to challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              isServer(challenge.protectionSpace),
              let identity = ClientIdentity.stored() else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    /// The headers a request to `url` carries, for places that build their own
    /// request (the background download session).
    public func headersToSend(for url: URL) -> [ProxyHeader] {
        lock.lock(); defer { lock.unlock() }
        return ProxyHeaders.headers(for: url, server: server, from: headers)
    }

    /// Options for an AVURLAsset opening `url`, `base` kept and the headers
    /// added when it is the server. Every AVURLAsset goes through `asset(url:)`.
    /// The AVURLAsset option that carries request headers. AVFoundation does not
    /// export it as a Swift symbol, but it is the key's real name and the one
    /// everything that sets headers on an asset uses.
    public static let assetHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    public func assetOptions(for url: URL, base: [String: Any] = [:]) -> [String: Any] {
        var options = base
        let extra = headersToSend(for: url)
        if !extra.isEmpty {
            options[Self.assetHeaderFieldsKey] = Dictionary(extra.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        return options
    }

    public func asset(url: URL, base: [String: Any] = [:]) -> AVURLAsset {
        let options = assetOptions(for: url, base: base)
        return AVURLAsset(url: url, options: options.isEmpty ? nil : options)
    }
}

/// Answers the server's request for a client certificate with the one the
/// person imported, and keeps the API's redirects on the server's host.
final class ProxySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let connection: ProxyConnection

    init(_ connection: ProxyConnection) { self.connection = connection }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        connection.respond(to: challenge)
    }

    /// A proxy's login redirect to another host (or another port on it) would
    /// otherwise carry the service token there. An http to https upgrade of
    /// the same address is fine.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url else { return request }
        return ProxyHeaders.redirectKeepsHeaders(from: from, to: to) ? request : nil
    }
}

/// The client certificate (a .p12 or .pfx the person picked), kept in the
/// keychain as an identity. AVPlayer does its own networking and may not use
/// it, so this is offered for the API, artwork and downloads, with playback
/// to be checked on a device.
public enum ClientIdentity {
    private static let label = "xyz.chaosinc.cascade.clientIdentity"

    public struct ImportError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Imports a PKCS#12 file and replaces any identity kept before.
    public static func save(p12 data: Data, passphrase: String) throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: passphrase] as CFDictionary, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]], let first = list.first,
              let any = first[kSecImportItemIdentity as String] else {
            throw ImportError(message: status == errSecAuthFailed
                              ? "That passphrase does not open the certificate."
                              : "Could not read that certificate (\(status)).")
        }
        let identity = any as! SecIdentity
        remove()
        let add: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw ImportError(message: "Could not save the certificate (\(added)).") }
    }

    public static func stored() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess, let ref else { return nil }
        return (ref as! SecIdentity)
    }

    /// What to call it in Settings, or nil when none is saved.
    public static func summary() -> String? {
        guard let identity = stored() else { return nil }
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return "Installed" }
        return SecCertificateCopySubjectSummary(cert) as String?
    }

    public static func remove() {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
    }
}
