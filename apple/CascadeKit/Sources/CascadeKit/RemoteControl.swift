import Foundation

// Both sides of Jellyfin remote control, the desktop's remote-control.ts and
// session-control.ts:
// - RemoteControl makes this app a target: "play on Cascade" from the web
//   app, another Cascade or any Jellyfin controller.
// - The JellyfinClient extension drives other sessions from here.

/// A command a controller sent, parsed from the socket's JSON.
public enum RemoteCommand: Equatable, Sendable {
    case play(itemIds: [String], startIndex: Int, mode: PlayMode)
    case playPause, pause, unpause, stop, next, previous
    case seek(ticks: Int)
    case setVolume(percent: Int)
    case volumeUp, volumeDown, toggleMute
    case setMute(Bool)
    /// The server's keep-alive interval, in seconds.
    case forceKeepAlive(seconds: Int)

    public enum PlayMode: String, Sendable { case now = "PlayNow", next = "PlayNext", last = "PlayLast" }

    /// Nil for anything this app does not act on. Numbers can arrive as
    /// strings (general command arguments always do).
    public static func parse(_ message: [String: Any]) -> RemoteCommand? {
        let data = message["Data"]
        switch message["MessageType"] as? String {
        case "ForceKeepAlive":
            return .forceKeepAlive(seconds: max(1, int(data) ?? 60))
        case "Play":
            guard let d = data as? [String: Any] else { return nil }
            let ids = (d["ItemIds"] as? [String] ?? []).filter { !$0.isEmpty }
            guard !ids.isEmpty else { return nil }
            return .play(itemIds: ids, startIndex: max(0, int(d["StartIndex"]) ?? 0),
                         mode: PlayMode(rawValue: d["PlayCommand"] as? String ?? "") ?? .now)
        case "Playstate", "PlayState":
            let d = data as? [String: Any] ?? [:]
            switch d["Command"] as? String {
            case "PlayPause": return .playPause
            case "Pause": return .pause
            case "Unpause": return .unpause
            case "Stop": return .stop
            case "NextTrack": return .next
            case "PreviousTrack": return .previous
            case "Seek": return .seek(ticks: max(0, int(d["SeekPositionTicks"]) ?? 0))
            default: return nil
            }
        case "GeneralCommand":
            let d = data as? [String: Any] ?? [:]
            let args = d["Arguments"] as? [String: Any] ?? [:]
            switch d["Name"] as? String {
            case "SetVolume": return .setVolume(percent: min(100, max(0, int(args["Volume"]) ?? 0)))
            case "VolumeUp": return .volumeUp
            case "VolumeDown": return .volumeDown
            case "ToggleMute": return .toggleMute
            case "Mute": return .setMute(true)
            case "Unmute": return .setMute(false)
            default: return nil
            }
        default:
            return nil
        }
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double, d.isFinite { return Int(d) }
        if let s = v as? String { return Int(s) ?? Double(s).flatMap { $0.isFinite ? Int($0) : nil } }
        return nil
    }
}

/// Makes this app a remote-control target. The socket is what makes it
/// castable: Jellyfin reports a session controllable only while it holds an
/// open one, so the capabilities are registered again on every connect (a
/// dropped socket takes the session's capabilities with it).
@MainActor
public final class RemoteControl {
    /// GeneralCommandType values only. Playstate commands (Pause, Seek, ...)
    /// are implied by SupportsMediaControl, and listing one here gets the
    /// whole registration refused with a 400, leaving the app invisible as a
    /// target. Only what `apply` handles: a declared command with no handler
    /// is a dead button in the controller.
    nonisolated static let supportedCommands = ["SetVolume", "ToggleMute", "Mute", "Unmute", "VolumeUp", "VolumeDown", "Play", "PlayState"]

    private let client: JellyfinClient
    private weak var player: PlaybackService?
    private var socket: URLSessionWebSocketTask?
    private var keepAlive: Task<Void, Never>?
    private var receiving: Task<Void, Never>?
    private var stopped = true

    public init(client: JellyfinClient, player: PlaybackService) {
        self.client = client
        self.player = player
    }

    public func start() {
        stopped = false
        Task { await open() }
    }

    public func stop() {
        stopped = true
        keepAlive?.cancel()
        receiving?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private struct Capabilities: Encodable {
        var playableMediaTypes = ["Audio"]
        var supportedCommands = RemoteControl.supportedCommands
        var supportsMediaControl = true
        var supportsPersistentIdentifier = true
    }

    private func open() async {
        guard !stopped, socket == nil else { return }
        let config = await client.currentConfig
        guard var url = URLComponents(string: config.url + "/socket") else { return }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.queryItems = [.init(name: "ApiKey", value: config.token), .init(name: "deviceId", value: config.deviceId)]
        guard let target = url.url else { return }
        let socket = URLSession.shared.webSocketTask(with: target)
        self.socket = socket
        socket.resume()
        send(["MessageType": "KeepAlive"])
        startKeepAlive(seconds: 30)
        Task { _ = try? await client.postRaw("/Sessions/Capabilities/Full", body: Capabilities()) }
        receiving = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .string(let text) = message,
                          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let command = RemoteCommand.parse(json) else { continue }
                    await self?.apply(command)
                } catch {
                    await self?.reconnect(after: socket)
                    return
                }
            }
        }
    }

    /// Five seconds, then again, while not stopped.
    ///
    /// ponytail: fixed interval, no backoff, as on the desktop. Back off if
    /// it ever hammers a server.
    private func reconnect(after dead: URLSessionWebSocketTask) async {
        guard socket === dead, !stopped else { return }
        keepAlive?.cancel()
        socket = nil
        try? await Task.sleep(for: .seconds(5))
        await open()
    }

    private func startKeepAlive(seconds: Int) {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                self?.send(["MessageType": "KeepAlive"])
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    /// Whether a command may be acted on. Transport is refused outright in a
    /// room rather than queued: a command that applies silently after the room
    /// ends is worse than one that visibly does nothing now. Volume and mute
    /// are personal to this device and never something a room or a cast
    /// drives, so they follow their own rule, not the transport one. Keep-alive
    /// is the socket's own housekeeping and always passes.
    nonisolated static func accepts(_ command: RemoteCommand, in state: OwnershipState) -> Bool {
        switch command {
        case .forceKeepAlive: return true
        case .setVolume, .volumeUp, .volumeDown, .toggleMute, .setMute:
            return Ownership.acceptsRemoteVolumeCommand(state)
        default: return Ownership.acceptsRemoteCommand(state)
        }
    }

    /// What the app says about a Waterfall room right now, so a cast and a
    /// room never both drive this player (see Ownership). Nil is "no room",
    /// which is what a standalone RemoteControl, and every test, means.
    public var ownership: (@MainActor () -> OwnershipState)?

    private func apply(_ command: RemoteCommand) async {
        guard let player else { return }
        guard Self.accepts(command, in: ownership?() ?? OwnershipState()) else { return }
        // A controller's play or skip would wake the paused song under a
        // movie, the same as a media key (see PlaybackService.isVideoActive).
        if player.isVideoActive?() == true {
            switch command {
            case .playPause, .unpause, .next, .previous, .seek: return
            default: break
            }
        }
        switch command {
        case .forceKeepAlive(let seconds): startKeepAlive(seconds: max(1, seconds / 2))
        case .play(let ids, let start, let mode):
            guard let items = try? await client.items(ids: ids), !items.isEmpty else { return }
            switch mode {
            case .now: await player.play(items, startIndex: min(start, items.count - 1))
            case .next: await player.playNext(items)
            case .last: await player.addToQueue(items)
            }
        case .playPause: player.togglePlayPause()
        case .pause: player.pause()
        case .unpause: player.resume()
        case .stop: await player.stop()
        case .next: await player.next()
        case .previous: await player.previous()
        case .seek(let ticks): await player.seek(to: Double(ticks) / Double(Lyrics.ticksPerSecond))
        case .setVolume(let percent): player.setVolume(Float(percent) / 100)
        case .volumeUp: player.setVolume(player.volume + 0.1)
        case .volumeDown: player.setVolume(player.volume - 0.1)
        case .toggleMute: player.setMuted(!player.isMuted)
        case .setMute(let muted): player.setMuted(muted)
        }
    }
}

/// Another session this user can drive.
public struct RemoteSession: Decodable, Identifiable, Sendable {
    public struct PlayState: Decodable, Sendable {
        public var positionTicks: Int?
        public var isPaused: Bool?
        public var volumeLevel: Int?
        public var isMuted: Bool?

        public init(positionTicks: Int? = nil, isPaused: Bool? = nil, volumeLevel: Int? = nil, isMuted: Bool? = nil) {
            self.positionTicks = positionTicks
            self.isPaused = isPaused
            self.volumeLevel = volumeLevel
            self.isMuted = isMuted
        }
    }

    public var id: String
    public var deviceId: String?
    public var deviceName: String?
    public var client: String?
    public var userName: String?
    public var supportsRemoteControl: Bool?
    public var nowPlayingItem: JfItem?
    public var playState: PlayState?

    public var label: String { deviceName ?? client ?? "Device" }

    public init(id: String, deviceId: String? = nil, deviceName: String? = nil, client: String? = nil,
                supportsRemoteControl: Bool? = nil, nowPlayingItem: JfItem? = nil, playState: PlayState? = nil) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.client = client
        self.supportsRemoteControl = supportsRemoteControl
        self.nowPlayingItem = nowPlayingItem
        self.playState = playState
    }
}

public enum SessionControl {
    /// Sessions worth listing: remote-controllable, and not this app itself,
    /// which registers as controllable too (so it can be cast to).
    public static func controllable(_ sessions: [RemoteSession], ownDeviceId: String) -> [RemoteSession] {
        sessions.filter { $0.supportsRemoteControl == true && $0.deviceId != ownDeviceId }
    }

    /// A polled position goes stale at once; this moves it on by the time
    /// since the poll, unless paused, so a progress bar does not freeze
    /// between polls.
    public static func position(_ state: RemoteSession.PlayState?, polledAt: Date, now: Date) -> Double {
        guard let ticks = state?.positionTicks else { return 0 }
        let seconds = Double(ticks) / Double(Lyrics.ticksPerSecond)
        return state?.isPaused == true ? seconds : seconds + max(0, now.timeIntervalSince(polledAt))
    }
}

public extension JellyfinClient {
    /// Items by id, in the order asked for (the server's own is not).
    func items(ids: [String]) async throws -> [JfItem] {
        let response: JfItemsResponse = try await get("/Items", params: [
            "userId": currentConfig.userId, "ids": ids.joined(separator: ","),
        ])
        let byId = Dictionary((response.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    func controllableSessions() async throws -> [RemoteSession] {
        let sessions: [RemoteSession] = try await get("/Sessions", params: [
            "controllableByUserId": currentConfig.userId, "activeWithinSeconds": "960",
        ])
        return SessionControl.controllable(sessions, ownDeviceId: currentConfig.deviceId)
    }

    /// A PlaystateCommand: PlayPause, Pause, Unpause, Stop, NextTrack,
    /// PreviousTrack, or Seek with `seekTicks`.
    func sendPlaystate(_ command: String, to sessionId: String, seekTicks: Int? = nil) async throws {
        _ = try await postRaw("/Sessions/\(sessionId)/Playing/\(command)", body: String?.none,
                              params: ["seekPositionTicks": seekTicks.map(String.init)])
    }

    /// The full general-command route, since the path-only one has nowhere
    /// to carry the volume.
    func setVolume(_ percent: Int, on sessionId: String) async throws {
        struct Command: Encodable { var name = "SetVolume"; var arguments: [String: String] }
        _ = try await postRaw("/Sessions/\(sessionId)/Command",
                              body: Command(arguments: ["Volume": String(min(100, max(0, percent)))]))
    }

    /// Nothing is sent for no items: the server would take it and do nothing,
    /// which reads as the device ignoring the command.
    func play(_ itemIds: [String], on sessionId: String, mode: RemoteCommand.PlayMode = .now,
              startIndex: Int = 0) async throws {
        let ids = itemIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        _ = try await postRaw("/Sessions/\(sessionId)/Playing", body: String?.none, params: [
            "playCommand": mode.rawValue, "itemIds": ids.joined(separator: ","), "startIndex": String(max(0, startIndex)),
        ])
    }
}
