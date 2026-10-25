import Foundation
import AVFoundation
import Security
#if os(macOS)
import CryptoKit
#endif

// Applies the reverse proxy headers and the client certificate to everything
// that talks to the Jellyfin server: the API sessions, artwork, the socket, the
// background download session and every AVURLAsset (music, video, preload).
// AVPlayer does its own networking, so URLSession configuration never reaches
// it: missing the asset path would make sign-in work and playback fail. The
// certificate reaches it on the Mac only (`preferForPlayback`).
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
        lock.lock()
        headers = clean
        lock.unlock()
        reconnect()
    }

    /// Drops the session so the next use builds a fresh one: new headers, or a
    /// different client certificate (open connections keep the old one).
    public func reconnect() {
        lock.lock(); defer { lock.unlock() }
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
        #if os(macOS)
        preferForPlayback(identity)
        #endif
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    #if os(macOS)
    private var preferred: String?

    /// AVPlayer's media loads never reach a URLSession or resource loader
    /// delegate (checked against an nginx with ssl_verify_client: direct
    /// streams and HLS segments alike), but on the Mac they do use the
    /// keychain's identity preference for the URL. SecIdentitySetPreferred
    /// keeps that per app ("<url> (Cascade)"), so Safari's choice is untouched.
    /// Set on the first certificate challenge (the API always goes first) and
    /// whenever the choice changes; nil clears it.
    func preferForPlayback(_ identity: SecIdentity?) {
        lock.lock()
        guard let server, let origin = ProxyHeaders.origin(of: server) else { lock.unlock(); return }
        let key = origin + " " + (identity.flatMap(ClientIdentity.certificate(of:)).map(ClientIdentity.fingerprint) ?? "")
        let fresh = key != preferred
        preferred = key
        lock.unlock()
        if fresh { SecIdentitySetPreferred(identity, (origin + "/") as CFString, nil) }
    }
    #endif

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

/// The client certificate, as a keychain identity.
///
/// iOS: a .p12 or .pfx the person imports, kept in the app's keychain under
/// one label.
///
/// macOS: any identity in the person's keychains, as on the desktop (which can
/// only pick from the system store). Importing a .p12 puts it in the login
/// keychain, where Safari and the desktop app see it too. The choice is kept by
/// fingerprint, in the desktop's `sha256/<base64>` form; forgetting it never
/// deletes anything from the keychain.
public enum ClientIdentity {
    public struct ImportError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static func importError(_ status: OSStatus) -> ImportError {
        let message = switch status {
        case errSecAuthFailed: "That passphrase does not open the certificate."
        case errSecDuplicateItem: "That certificate is already in your keychain: choose it from the list."
        default: "Could not read that certificate (\(status))."
        }
        return ImportError(message: message)
    }

    /// The identities a PKCS#12 file holds. On macOS the import also adds them
    /// to the login keychain.
    static func importP12(_ data: Data, passphrase: String) throws -> [SecIdentity] {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: passphrase] as CFDictionary, &items)
        guard status == errSecSuccess else { throw importError(status) }
        let found = (items as? [[String: Any]] ?? []).compactMap { $0[kSecImportItemIdentity as String] }.map { $0 as! SecIdentity }
        guard !found.isEmpty else { throw ImportError(message: "That file holds no certificate with its private key.") }
        return found
    }

    static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var cert: SecCertificate?
        return SecIdentityCopyCertificate(identity, &cert) == errSecSuccess ? cert : nil
    }

    #if os(macOS)
    /// One identity the person can pick.
    public struct Choice: Identifiable, Hashable, Sendable {
        public let id: String          // fingerprint
        public let name: String
        public let issuer: String?
        public let expires: Date?
    }

    private static let defaultsKey = "cascade.clientCertFingerprint"
    private static let cache = IdentityCache()

    /// The desktop's form (Chromium's): SHA-256 of the DER certificate.
    public static func fingerprint(_ cert: SecCertificate) -> String {
        "sha256/" + Data(SHA256.hash(data: SecCertificateCopyData(cert) as Data)).base64EncodedString()
    }

    private static func allIdentities() -> [SecIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess, let list = ref as? [Any] else { return [] }
        return list.map { $0 as! SecIdentity }
    }

    private static func describe(_ cert: SecCertificate) -> Choice {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(cert, keys, nil) as? [String: [String: Any]] ?? [:]
        let issuer = (values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]])?
            .first { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDCommonName as String }?[kSecPropertyKeyValue as String] as? String
        let notAfter = (values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber)
            .map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
        return Choice(id: fingerprint(cert), name: SecCertificateCopySubjectSummary(cert) as String? ?? "Certificate",
                      issuer: issuer, expires: notAfter)
    }

    /// Every identity in the keychains, expired ones left out as on the desktop
    /// (the server would refuse them and the failure would be blank).
    public static func available(now: Date = Date()) -> [Choice] {
        var seen = Set<String>()
        return allIdentities().compactMap { certificate(of: $0).map(describe) }
            .filter { ($0.expires ?? .distantFuture) > now && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static var chosen: String? { UserDefaults.standard.string(forKey: defaultsKey) }

    /// Picks the identity to answer with (nil: none), from the next connection on.
    public static func choose(_ fingerprint: String?) {
        UserDefaults.standard.set(fingerprint, forKey: defaultsKey)
        cache.clear()
        ProxyConnection.shared.preferForPlayback(stored())
        ProxyConnection.shared.reconnect()
    }

    /// Imports a .p12 into the login keychain and chooses it.
    public static func save(p12 data: Data, passphrase: String) throws {
        guard let cert = try importP12(data, passphrase: passphrase).first.flatMap(certificate(of:)) else {
            throw ImportError(message: "Could not read that certificate.")
        }
        choose(fingerprint(cert))
    }

    /// The chosen identity. Asked on every TLS handshake, so the keychain
    /// search runs only when the choice changes.
    public static func stored() -> SecIdentity? {
        guard let wanted = chosen else { return nil }
        if let hit = cache.get(wanted) { return hit }
        let found = allIdentities().first { certificate(of: $0).map(fingerprint) == wanted }
        if let found { cache.set(wanted, found) }
        return found
    }

    /// Forgets the choice; the identity stays in the keychain.
    public static func remove() { choose(nil) }
    #else
    private static let label = "xyz.chaosinc.cascade.clientIdentity"

    /// Imports a PKCS#12 file and replaces any identity kept before.
    public static func save(p12 data: Data, passphrase: String) throws {
        let identity = try importP12(data, passphrase: passphrase)[0]
        remove()
        let add: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw ImportError(message: "Could not save the certificate (\(added)).") }
        ProxyConnection.shared.reconnect()
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
        guard let cert = certificate(of: identity) else { return "Installed" }
        return SecCertificateCopySubjectSummary(cert) as String?
    }

    public static func remove() {
        SecItemDelete([kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: label] as CFDictionary)
        ProxyConnection.shared.reconnect()
    }
    #endif
}

#if os(macOS)
private final class IdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (String, SecIdentity)?
    func get(_ key: String) -> SecIdentity? { lock.lock(); defer { lock.unlock() }; return entry?.0 == key ? entry?.1 : nil }
    func set(_ key: String, _ value: SecIdentity) { lock.lock(); entry = (key, value); lock.unlock() }
    func clear() { lock.lock(); entry = nil; lock.unlock() }
}
#endif
