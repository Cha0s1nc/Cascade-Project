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
    /// Which route family the server's Cascade plugin answers on, once probed.
    /// Nil until then, and stays nil when the plugin is absent: no lyrics.
    private(set) var cascadePluginApi: CascadePluginApi?
    /// The plugin has a SpicyLyrics key (its "syllable" capability).
    private(set) var cascadePluginSpicy = false

    var isSignedIn: Bool { client != nil }

    /// Each browse screen's list, owned here rather than by the screen. A
    /// screen's own .task is cancelled the moment it disappears (a tab switch,
    /// or opening a detail page), so a library that takes a while to page in
    /// never finished while the user moved around, and every return started
    /// again from an empty screen. Loaded here, a list keeps filling in the
    /// background and coming back shows whatever has arrived. Keyed by the
    /// screen and everything its list depends on (library selection, sort,
    /// filter). Memory only, for this session: pull to refresh drops a
    /// screen's lists, a playlist write drops Playlists', and signing out
    /// drops them all. Ignored by observation: screens observe the BrowseList
    /// they are handed, not this dictionary.
    @ObservationIgnored private var browseLists: [BrowseCacheKey: BrowseList] = [:]

    /// The list for this screen and key, starting its load if there is none
    /// yet or the last one failed. Asking for a new key cancels the screen's
    /// other unfinished loads, so flicking through sorts does not leave a
    /// queue of whole-library fetches running.
    func browseList(_ screen: BrowseScreen, _ key: BrowseKey,
                    load: @escaping @MainActor (BrowseList) async throws -> Void) -> BrowseList {
        let cacheKey = BrowseCacheKey(screen: screen, key: key)
        if let list = browseLists[cacheKey], list.error == nil { return list }
        for (other, list) in browseLists where other.screen == screen && !list.isComplete {
            list.task?.cancel()
            browseLists[other] = nil
        }
        let list = BrowseList()
        browseLists[cacheKey] = list
        list.task = Task {
            do {
                try await load(list)
                list.isComplete = !Task.isCancelled
            } catch {
                if !Task.isCancelled { list.error = error.localizedDescription }
            }
            list.isLoading = false
        }
        return list
    }

    func dropBrowseCache(_ screen: BrowseScreen) {
        for (key, list) in browseLists where key.screen == screen {
            list.task?.cancel()
            browseLists[key] = nil
        }
    }

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

    /// Bring back the last session without asking for a password again.
    ///
    /// ponytail: optimistic. A token revoked server-side since last launch
    /// leaves every screen showing a 401 until the user signs out from
    /// Settings. Add a 401 interceptor that clears the session automatically if
    /// that turns out to happen in practice rather than in theory.
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
        persist(server: server, auth: auth)
    }

    /// Finish a QuickConnect sign-in once the code has been approved. Saves the
    /// session exactly as a password sign-in does, so restore() cannot tell
    /// them apart.
    func signIn(server: String, quickConnectSecret secret: String) async throws {
        let auth = try await QuickConnect.authenticate(serverUrl: server, secret: secret,
                                                       appVersion: appVersion, deviceId: Self.deviceId)
        persist(server: server, auth: auth)
    }

    /// The signed-in user's display name, for Settings. Saved at sign-in;
    /// Settings fills it in for sessions signed in before it was saved.
    var username: String? {
        get { UserDefaults.standard.string(forKey: "cascade.username") }
        set { UserDefaults.standard.set(newValue, forKey: "cascade.username") }
    }

    private func persist(server: String, auth: JfAuthResult) {
        username = auth.user.name
        let server = server.hasSuffix("/") ? String(server.dropLast()) : server
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
        UserDefaults.standard.removeObject(forKey: "cascade.username")
        config = nil
        client = nil
        player = nil
        cascadePluginApi = nil
        for list in browseLists.values { list.task?.cancel() }
        browseLists = [:]
    }

    /// Which music libraries to browse. Empty means all of them.
    ///
    /// Updates the existing client rather than going through `adopt`, which
    /// would build a new PlaybackService and stop whatever is playing. Changing
    /// a browsing preference in Settings has no business interrupting a track.
    ///
    /// The client is updated BEFORE the published config changes: screens
    /// reload when the config's library list changes, and reloading first
    /// meant querying the client while it still held the old selection.
    func setLibraries(_ ids: [String]) async {
        guard var config else { return }
        config.libraryIds = ids
        UserDefaults.standard.set(ids, forKey: "cascade.libraryIds")
        await client?.update(config: config)
        self.config = config
    }

    private func adopt(_ config: ServerConfig) {
        self.config = config
        let client = JellyfinClient(config: config)
        self.client = client
        // Rebuilt with the client so the player never holds a stale token or a
        // stale library selection.
        let player = PlaybackService(client: client, config: config)
        player.setStreamingQuality(
            wifi: StreamingQuality(stored: UserDefaults.standard.object(forKey: StreamingQuality.wifiKey)),
            cellular: StreamingQuality(stored: UserDefaults.standard.object(forKey: StreamingQuality.cellularKey)))
        self.player = player
        cascadePluginApi = nil
        Task {
            let (probe, api, capabilities) = await client.probeCascadePlugin()
            // 'unknown' counts as present: a network hiccup must not hide
            // lyrics for the whole session. A wrong guess just 404s per track.
            if probe != .absent, self.client === client {
                cascadePluginApi = api
                cascadePluginSpicy = capabilities.contains("syllable")
            }
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
