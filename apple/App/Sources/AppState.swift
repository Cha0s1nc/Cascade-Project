import Foundation
import Observation
import CascadeKit

/// Everything the app needs once, held in one place: who is signed in, the
/// client that talks to their server, and the player.
///
/// Screens read this from the environment. Nothing constructs its own client,
/// so there is exactly one session and one player for the whole app.
@MainActor
@Observable
final class AppState {
    private(set) var config: ServerConfig?
    private(set) var client: JellyfinClient?
    private(set) var player: PlaybackService?

    var isSignedIn: Bool { client != nil }

    /// Unique per install. A constant here would make every Cascade look like
    /// the same device to the server, so remote control could not target one of
    /// them and two installs would collide in the session list.
    static var deviceId: String {
        let key = "cascade.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    init() {
        restore()
    }

    /// Bring back the last session without asking for a password again. The
    /// token can have been revoked server-side since, so this is optimistic:
    /// the first request that comes back 401 sends the user to sign in.
    private func restore() {
        guard let token = Keychain.get("token"),
              let url = UserDefaults.standard.string(forKey: "cascade.serverUrl"),
              let userId = UserDefaults.standard.string(forKey: "cascade.userId")
        else { return }
        let libraryIds = UserDefaults.standard.stringArray(forKey: "cascade.libraryIds") ?? []
        adopt(ServerConfig(url: url, token: token, userId: userId,
                           libraryIds: libraryIds, deviceId: Self.deviceId))
    }

    func signIn(server: String, username: String, password: String) async throws {
        let auth = try await authenticate(serverUrl: server, username: username,
                                          password: password, appVersion: appVersion,
                                          deviceId: Self.deviceId)
        let config = ServerConfig(url: server, token: auth.accessToken,
                                  userId: auth.user.id, deviceId: Self.deviceId)
        Keychain.set(config.token, for: "token")
        UserDefaults.standard.set(config.url, forKey: "cascade.serverUrl")
        UserDefaults.standard.set(config.userId, forKey: "cascade.userId")
        adopt(config)
    }

    func signOut() async {
        await player?.stop()
        Keychain.remove("token")
        UserDefaults.standard.removeObject(forKey: "cascade.userId")
        UserDefaults.standard.removeObject(forKey: "cascade.libraryIds")
        config = nil
        client = nil
        player = nil
    }

    /// Which music libraries to browse. Empty means all of them.
    func setLibraries(_ ids: [String]) {
        guard var config else { return }
        config.libraryIds = ids
        UserDefaults.standard.set(ids, forKey: "cascade.libraryIds")
        adopt(config)
    }

    private func adopt(_ config: ServerConfig) {
        self.config = config
        let client = JellyfinClient(config: config)
        self.client = client
        // Rebuilt with the client so the player never holds a stale token or a
        // stale library selection.
        self.player = PlaybackService(client: client, config: config)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
