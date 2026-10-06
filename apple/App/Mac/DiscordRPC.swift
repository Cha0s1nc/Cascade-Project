import Foundation
import Network
import Observation
import CascadeKit

/// Discord Rich Presence over Discord's local socket, a port of main.js ~139-255 and the
/// renderer's `updateDiscordPresence`. The frame format, activity JSON, backoff and throttle math
/// are CascadeKit's (DiscordRPC.swift there, tested); this is the socket and the timing.
@MainActor
@Observable
final class DiscordClient {
    static let defaultClientId = "1512373702522835004"
    /// Feeds the Settings status dot.
    private(set) var connected = false

    @ObservationIgnored private var conn: NWConnection?
    @ObservationIgnored private var buffer = Data()
    /// The client id RPC should be running with; nil means off.
    @ObservationIgnored private var desiredId: String?
    @ObservationIgnored private var backoff = RpcBackoff()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    /// Bumped per connection attempt, so a late callback from a replaced socket is ignored.
    @ObservationIgnored private var generation = 0

    // Presence state.
    @ObservationIgnored private var lastActivity: DiscordActivity?
    @ObservationIgnored private var sendTimer: Task<Void, Never>?
    @ObservationIgnored private var lastSentAt = 0.0
    @ObservationIgnored private var artToken = 0
    /// What the last push described, so the poll only pushes when something changed.
    @ObservationIgnored private var lastKey: String?
    @ObservationIgnored private var anchorStart = 0

    // MARK: settings

    /// Applies the settings; a no-op when they are unchanged.
    func configure(enabled: Bool, clientId: String) {
        let want = enabled ? (clientId.isEmpty ? Self.defaultClientId : clientId) : nil
        guard want != desiredId else { return }
        desiredId = want
        shutdown()
        if want != nil { connect() }
    }

    private func shutdown() {
        reconnectTask?.cancel(); reconnectTask = nil
        backoff.reset()
        clearPresence()
        teardown()
        lastKey = nil
    }

    // MARK: presence

    /// Called every second with what is playing. Re-sends only on a track change, a resume, a seek
    /// or a fresh connection; pausing clears the presence outright rather than freezing the bar.
    func present(_ m: MacIntegrations.Media?) {
        guard desiredId != nil else { return }
        guard let m, m.playing else {
            if lastKey != nil { clearPresence(); lastKey = nil }
            return
        }
        let start = Int(Date().timeIntervalSince1970 * 1000 - m.position * 1000)
        // A drift from the anchor means the head moved without a track change: a seek.
        guard m.item.id != lastKey || abs(start - anchorStart) > 2500 else { return }
        lastKey = m.item.id
        anchorStart = start
        push(m, startMs: start)
    }

    private func push(_ m: MacIntegrations.Media, startMs: Int) {
        artToken += 1
        let token = artToken
        let item = m.item
        var activity = DiscordActivity.make(item: item, startMs: startMs, fallbackDurationMs: m.duration.map { $0 * 1000 })
        let artist = item.albumArtist ?? item.artists?.first ?? ""
        let album = item.album ?? ""
        if m.video || (artist.isEmpty && album.isEmpty) { send(activity); return }
        // Give the cover 800 ms to land so the first push carries it; a slower one follows. Public
        // iTunes URLs only: Jellyfin's image URL carries the token and must never go to Discord.
        Task {
            let wait = await ITunesArt.shared.art(artist: artist, album: album, within: 800)
            guard token == artToken, desiredId != nil else { return }
            if case .found(let url) = wait { activity.largeImage = url }
            send(activity)
            guard wait == .pending else { return }
            guard let late = await ITunesArt.shared.art(artist: artist, album: album),
                  token == artToken, desiredId != nil else { return }
            activity.largeImage = late
            send(activity)
        }
    }

    /// At most one update per 5 s; a later one replaces whatever is waiting.
    private func send(_ activity: DiscordActivity) {
        lastActivity = activity
        guard sendTimer == nil else { return }
        let wait = rpcSendWait(now: Date().timeIntervalSince1970, lastSentAt: lastSentAt)
        if wait <= 0 { flush(); return }
        sendTimer = Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        sendTimer = nil
        guard connected else { return }
        lastSentAt = Date().timeIntervalSince1970
        write(DiscordFrame.setActivity(lastActivity, pid: getpid(), nonce: UUID().uuidString))
    }

    /// Drops the waiting update as well as the live one: the throttle holds the last activity to
    /// send when its timer fires, so clearing alone would let it put the presence back up.
    func clearPresence() {
        artToken += 1
        lastActivity = nil
        sendTimer?.cancel(); sendTimer = nil
        if connected { write(DiscordFrame.setActivity(nil, pid: getpid(), nonce: UUID().uuidString)) }
    }

    // MARK: socket

    private func connect() {
        guard desiredId != nil else { return }
        generation += 1
        tryConnect(index: 0, gen: generation)
        let gen = generation
        // No READY in 10 s: the socket is not Discord's, or Discord is wedged.
        timeoutTask?.cancel()
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, gen == generation, !connected else { return }
            lost()
        }
    }

    private func tryConnect(index: Int, gen: Int) {
        guard gen == generation else { return }
        guard index <= 9 else { lost(); return }
        let path = NSTemporaryDirectory() + "discord-ipc-\(index)"
        // A path with nothing behind it is skipped without a connection attempt.
        guard FileManager.default.fileExists(atPath: path) else { tryConnect(index: index + 1, gen: gen); return }
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        conn = c
        var started = false
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.conn === c else { return }
                switch state {
                case .ready:
                    started = true
                    self.buffer = Data()
                    if let id = self.desiredId { self.write(DiscordFrame.handshake(clientId: id)) }
                    self.receive(c, gen: gen)
                case .failed, .waiting:
                    c.cancel()
                    if started { self.lost() } else { self.conn = nil; self.tryConnect(index: index + 1, gen: gen) }
                default: break
                }
            }
        }
        c.start(queue: .main)
    }

    private func receive(_ c: NWConnection, gen: Int) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.conn === c else { return }
                if let data { self.buffer.append(data) }
                for frame in DiscordFrame.decode(&self.buffer) { self.handle(frame.op, frame.payload) }
                if done || error != nil { self.lost() } else if self.conn === c { self.receive(c, gen: gen) }
            }
        }
    }

    private func handle(_ op: UInt32, _ payload: Data) {
        switch DiscordOp(rawValue: op) {
        case .ping: write(DiscordFrame.encode(op: .pong, payload: payload))
        case .close: lost()
        case .frame:
            guard (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["evt"] as? String == "READY" else { return }
            timeoutTask?.cancel()
            connected = true
            backoff.reset()
            reconnectTask?.cancel(); reconnectTask = nil
            // A track already playing when the handshake finished had its presence dropped, so push it again.
            lastKey = nil
        default: break
        }
    }

    private func write(_ data: Data) {
        conn?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func teardown() {
        timeoutTask?.cancel(); timeoutTask = nil
        generation += 1
        let c = conn
        conn = nil
        c?.stateUpdateHandler = nil
        c?.cancel()
        buffer = Data()
        connected = false
    }

    /// Discord quit, crashed or is not running: there is no "came back" event, so retry on a timer.
    private func lost() {
        teardown()
        guard desiredId != nil, reconnectTask == nil else { return }
        let delay = backoff.next()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            reconnectTask = nil
            connect()
        }
    }
}
