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
    /// Makes this app a target for "play on" from other Jellyfin clients.
    private var remoteControl: RemoteControl?
    /// Listening along with others (Waterfall). One per sign-in, like the player.
    private(set) var waterfall: WaterfallSession?

    /// Music or Video: which library the tabs browse, the desktop's toggle.
    enum BrowseMode: String { case music, video }
    var browseMode = BrowseMode(rawValue: UserDefaults.standard.string(forKey: "cascade.browseMode") ?? "") ?? .music {
        didSet { UserDefaults.standard.set(browseMode.rawValue, forKey: "cascade.browseMode") }
    }

    /// The Mac's Now Playing overlay is showing.
    var nowPlayingOpen = false

    /// Bumped by Command-comma; the Mac shell shows its Settings section.
    var settingsRequests = 0

    /// From the user's Policy (Permissions). False until it has been read and
    /// for any failure: gated items stay dimmed rather than offered and refused.
    private(set) var isAdmin = false
    private(set) var canDelete = false
    func setPolicy(_ policy: UserPolicy?) {
        isAdmin = Permissions.isAdmin(policy: policy)
        canDelete = Permissions.canDeleteMedia(policy: policy)
    }

    /// Bumped by `playlistMutated`; an open playlist page reloads when it changes.
    private(set) var playlistRevision = 0
    /// The one choke point every playlist write goes through (the desktop's
    /// playlistMutated): drops the Playlists list and tells open pages to
    /// reload, so no screen keeps showing what the server no longer has.
    func playlistMutated() {
        dropBrowseCache(.playlists)
        playlistRevision += 1
    }
    /// Bumped after a metadata edit or a delete so pages refetch their items.
    private(set) var libraryRevision = 0
    func libraryMutated() {
        for screen in [BrowseScreen.albums, .artists, .songs, .playlists] { dropBrowseCache(screen) }
        libraryRevision += 1
    }

    /// The movie and TV libraries browsed, apart from the music selection.
    let videoLibraries = VideoLibrarySelection()

    /// Internet radio: the person has confirmed their server's Live TV
    /// channels are radio stations (Jellyfin cannot say which are), the
    /// desktop's `radioEnabled`. The Radio section also needs `hasLiveTv`.
    var radioEnabled = UserDefaults.standard.bool(forKey: radioEnabledKey) {
        didSet { UserDefaults.standard.set(radioEnabled, forKey: radioEnabledKey) }
    }
    /// This account may use Live TV (its policy). False until asked, and for
    /// an account without it, where the Radio section would only 403.
    private(set) var hasLiveTv = false
    /// Whether to show Radio at all: opted in, and the account has Live TV.
    var showsRadio: Bool { radioEnabled && hasLiveTv }

    #if os(macOS)
    /// Saves and restores the queue, volume, repeat and output device.
    private var playbackPersistence: PlaybackPersistence?
    #endif

    /// The movie or episodes playing, shown full screen while set.
    var videoSession: VideoSession?

    /// Plays movies or episodes in Apple's player, pausing any music first.
    func playVideo(_ items: [JfItem], startIndex: Int = 0, audioStreamIndex: Int? = nil, resume: Bool = true) async {
        guard let client, let config else { return }
        // A guest's pause would go to the host (the transport gate) and stop
        // the whole room, or explain host control at an odd moment: leave the
        // room instead. A host pausing their own room is fine.
        if waterfall?.role == .guest {
            waterfall?.leave(reason: "Left the Waterfall room to play a video.")
        }
        player?.pause()
        // The video takes the lock screen until it closes.
        player?.lockScreenSuspended = true
        let session = videoSession ?? VideoSession(client: client, config: config)
        videoSession = session
        // The Video EQ curve (video agent: the music service only holds it).
        session.setEqualizer(equalizer(for: .video))
        #if os(macOS)
        session.follow(player)
        #endif
        await session.play(items, startIndex: startIndex, audioStreamIndex: audioStreamIndex, resume: resume)
    }

    /// One tile's worth: an episode plays on through the rest of its season.
    func playVideoItem(_ item: JfItem) async {
        guard let client else { return }
        if item.type == "Episode", let series = item.seriesId,
           let season = try? await client.episodes(of: series, season: item.seasonId),
           let index = season.firstIndex(where: { $0.id == item.id }) {
            await playVideo(season, startIndex: index)
        } else {
            await playVideo([item])
        }
    }

    /// Bumped once a closed video's stopped report has landed, so pages
    /// refetch resume points and Next Up after the server has them, not
    /// before (they raced, and a page showed Play instead of Resume).
    private(set) var videoRevision = 0

    func closeVideo() {
        guard let session = videoSession else { return }
        videoSession = nil
        Task {
            await session.stop()
            player?.lockScreenSuspended = false
            videoRevision += 1
        }
    }

    /// Downloaded albums and playlists. One for the app's life, not per
    /// sign-in: it owns the background download session. None on tvOS.
    #if os(iOS)
    let offline: OfflineLibrary? = OfflineLibrary()
    #else
    let offline: OfflineLibrary? = nil
    #endif

    /// The other device picked in the Devices sheet: song menus offer
    /// "Play on" it while one is picked.
    var controlledDevice: (id: String, name: String)?

    /// What the plugin's Info says it can do (SpicyLyrics, Spotify links).
    private(set) var cascadePluginInfo = CascadePluginInfo()

    /// Lyrics from Cascade Server alone (SpicyLyrics, then lyrics saved on
    /// the server), never Kugou, LRCLIB or Jellyfin. On unless turned off:
    /// it is how this app always fetched, and how the desktop is set up here.
    /// Ignored while the plugin is absent, when it would mean no lyrics.
    var serverOnlyLyrics = UserDefaults.standard.object(forKey: "cascade.serverOnlyLyrics") as? Bool ?? true {
        didSet { UserDefaults.standard.set(serverOnlyLyrics, forKey: "cascade.serverOnlyLyrics") }
    }

    /// Songs this user linked to a Spotify track on this device only (item id
    /// to Spotify id), for a server that does not let them link songs for
    /// everyone. Sent with each lyrics request. Read back through
    /// Spotify.trackId, since stored values are not trusted.
    private(set) var localSpotifyLinks: [String: String] = {
        let raw = UserDefaults.standard.dictionary(forKey: "cascade.spotifyLinks") as? [String: String] ?? [:]
        return raw.compactMapValues(Spotify.trackId)
    }()

    func setLocalSpotifyLink(itemId: String, spotifyId: String?) {
        localSpotifyLinks[itemId] = spotifyId
        UserDefaults.standard.set(localSpotifyLinks, forKey: "cascade.spotifyLinks")
    }

    /// Smart playlists made on this device (the desktop keeps them locally
    /// too: Jellyfin has no such thing). Validated when read back.
    private(set) var smartPlaylists = SmartPlaylist.stored(in: .standard)

    /// Adds the playlist, or replaces the one with its id.
    func saveSmartPlaylist(_ playlist: SmartPlaylist) {
        guard let playlist = playlist.validated() else { return }
        if let i = smartPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            smartPlaylists[i] = playlist
        } else {
            smartPlaylists.append(playlist)
        }
        UserDefaults.standard.set(SmartPlaylist.encodeList(smartPlaylists), forKey: "cascade.smartPlaylists")
    }

    func deleteSmartPlaylist(id: String) {
        smartPlaylists.removeAll { $0.id == id }
        UserDefaults.standard.set(SmartPlaylist.encodeList(smartPlaylists), forKey: "cascade.smartPlaylists")
    }

    /// Bumped when a song's lyrics are worth asking for again (a Spotify link
    /// changed on the server).
    var lyricsRevision = 0

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
    ///
    /// `localSort` is the server sortBy this key asks for, when the list is the
    /// whole library in that order. Then a whole list already loaded for the
    /// same screen, libraries and filter in another order is re-sorted here
    /// instead of fetched again: changing the sort is instant after the first
    /// load, as the desktop's is.
    func browseList(_ screen: BrowseScreen, _ key: BrowseKey, localSort: String? = nil,
                    load: @escaping @MainActor (BrowseList) async throws -> Void) -> BrowseList {
        let cacheKey = BrowseCacheKey(screen: screen, key: key)
        if let list = browseLists[cacheKey], list.error == nil { return list }
        if let localSort, sortsLikeServer(localSort),
           let source = browseLists.first(where: { other, list in
               other.screen == screen && list.isWholeList && list.isComplete && list.error == nil
                   && other.key.libraries == key.libraries && other.key.filter == key.filter
                   && other.key.generation == key.generation
           })?.value {
            let list = BrowseList()
            list.items = sortedLikeServer(source.items, sortBy: localSort, sortOrder: key.direction.serverValue)
            list.isWholeList = true
            list.isComplete = true
            list.isLoading = false
            list.nextStart = source.nextStart
            browseLists[cacheKey] = list
            return list
        }
        for (other, list) in browseLists where other.screen == screen && !list.isComplete {
            list.task?.cancel()
            browseLists[other] = nil
        }
        let list = BrowseList()
        list.isWholeList = localSort != nil
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
        #if os(macOS)
        // Before restore(): the Electron app's session and device id, when
        // there is one to bring across, are what it should find.
        MacSettingsImport.runOnce()
        #endif
        // Before restore() builds the client: a proxy that wants a header refuses
        // even the first request without it.
        ProxyConnection.shared.setHeaders(ProxyHeaderStore.load())
        ProxyConnection.shared.setServer(UserDefaults.standard.string(forKey: "cascade.serverUrl"))
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
        ProxyConnection.shared.setServer(server)
        let config = ServerConfig(url: server, token: auth.accessToken,
                                  userId: auth.user.id, deviceId: Self.deviceId)
        Keychain.set(config.token, for: "token")
        UserDefaults.standard.set(config.url, forKey: "cascade.serverUrl")
        UserDefaults.standard.set(config.userId, forKey: "cascade.userId")
        adopt(config)
    }

    func signOut() async {
        #if os(macOS)
        playbackPersistence?.stop(clearingSavedQueue: true)
        playbackPersistence = nil
        #endif
        await player?.stop()
        // Stops this account's downloads and hides them from whoever is next.
        offline?.setOwner(nil)
        Keychain.remove("token")
        UserDefaults.standard.removeObject(forKey: "cascade.userId")
        UserDefaults.standard.removeObject(forKey: "cascade.libraryIds")
        UserDefaults.standard.removeObject(forKey: "cascade.username")
        config = nil
        client = nil
        player = nil
        remoteControl?.stop()
        remoteControl = nil
        waterfall?.leave()
        waterfall = nil
        hasLiveTv = false
        setPolicy(nil)
        closeVideo()
        controlledDevice = nil
        cascadePluginApi = nil
        cascadePluginInfo = .init()
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
        player.normalization = Normalization.Mode(
            rawValue: UserDefaults.standard.string(forKey: "cascade.normalization") ?? "") ?? .off
        player.equalizer = EQProfile.decode(UserDefaults.standard.data(forKey: "cascade.eq"))
        // Stored values are clamped: 0 (off) or the settings range.
        let fade = UserDefaults.standard.integer(forKey: "cascade.crossfadeSeconds")
        player.crossfadeSeconds = Crossfade.range.contains(fade) ? Double(fade) : 0
        player.offline = offline
        player.videoEqualizer = EQProfile.decode(UserDefaults.standard.data(forKey: EQKind.video.storageKey))
        // The music service's media keys and remote commands stay out of the
        // way while a video is on. Read from the session itself, so no way of
        // closing a video can leave them dead.
        player.isVideoActive = { [weak self] in self?.videoSession != nil }
        self.player = player
        #if os(macOS)
        playbackPersistence?.stop()
        playbackPersistence = PlaybackPersistence(player: player, client: client)
        playbackPersistence?.start()
        #endif
        if let offline {
            // This account's downloads; another's are never listed or resumed.
            offline.setOwner(config.userId)
            Task {
                await offline.resume(client: client)
                await offline.replayPlays(client: client)
            }
        }
        waterfall?.leave()
        waterfall = WaterfallSession(client: client, player: player)
        // Castable from other Jellyfin clients for as long as this player lives.
        remoteControl?.stop()
        remoteControl = RemoteControl(client: client, player: player)
        // A cast and a Waterfall room never both drive this player: the room
        // wins, and remote volume is refused in one (see Ownership).
        remoteControl?.ownership = { [weak self] in
            let room = self?.waterfall
            return OwnershipState(waterfallActive: room?.isActive ?? false, waterfallIsHost: room?.role == .host,
                                  guestAddsAllowed: room?.guestAddsAllowed)
        }
        remoteControl?.start()
        hasLiveTv = false
        setPolicy(nil)   // a previous account's rights must not outlive it
        Task {
            let policy = try? await client.userPolicy()
            if self.client === client { setPolicy(policy) }
        }
        Task {
            let access = (try? await client.hasLiveTvAccess()) ?? false
            if self.client === client { hasLiveTv = access }
        }
        cascadePluginApi = nil
        cascadePluginInfo = .init()
        Task {
            let (probe, api, info) = await client.probeCascadePlugin()
            // 'unknown' counts as present: a network hiccup must not hide
            // lyrics for the whole session. A wrong guess just 404s per track.
            if probe != .absent, self.client === client {
                cascadePluginApi = api
                cascadePluginInfo = info
            }
        }
    }

    func setEqualizer(_ profile: EQProfile) {
        player?.equalizer = profile
        UserDefaults.standard.set(profile.encoded(), forKey: "cascade.eq")
    }

    /// The Music or Video curve. Video's is applied by the video player; this
    /// only keeps and saves it, beside music's.
    func equalizer(for kind: EQKind) -> EQProfile {
        switch kind {
        case .music: player?.equalizer ?? EQProfile.decode(UserDefaults.standard.data(forKey: kind.storageKey))
        case .video: player?.videoEqualizer ?? EQProfile.decode(UserDefaults.standard.data(forKey: kind.storageKey))
        }
    }

    func setEqualizer(_ profile: EQProfile, for kind: EQKind) {
        switch kind {
        case .music: player?.equalizer = profile
        case .video:
            player?.videoEqualizer = profile
            videoSession?.setEqualizer(profile)
        }
        UserDefaults.standard.set(profile.encoded(), forKey: kind.storageKey)
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
