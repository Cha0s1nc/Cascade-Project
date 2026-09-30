import Foundation
import Observation

/// A Waterfall room: the desktop's waterfall.js, minus its DOM. The host owns
/// playback and announces it; guests follow with their own streams from the
/// same server, and send the host anything else they want (a skip, a song
/// for the queue) when the host allows it.
///
/// The relay only forwards JSON between members; see WaterfallProtocol.swift
/// for the messages and the sync maths.
@MainActor
@Observable
public final class WaterfallSession {
    public enum Role: Sendable { case host, guest }
    public struct Member: Sendable, Equatable, Identifiable, Decodable {
        public var id: String
        public var name: String
    }

    public private(set) var code: String?
    public private(set) var role: Role?
    public private(set) var memberId: String?
    public private(set) var roster: [Member] = []
    /// Something to tell the person: the room ended, a track they cannot
    /// play, a refused request. The app shows it and clears it.
    public var notice: String?
    /// Host: its settings. Guest: what the host last said.
    public private(set) var guestAddsAllowed = true
    public private(set) var guestControlAllowed = false

    public var isActive: Bool { code != nil }

    private let client: JellyfinClient
    private let player: PlaybackService
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var serverId: String?

    // Host
    @ObservationIgnored private var queueRev = 0
    @ObservationIgnored private var addedBy: [String?] = []
    @ObservationIgnored private var publishedQueue: [String] = []
    @ObservationIgnored private var published: (trackId: String, paused: Bool, index: Int, positionMs: Double, at: Double)?
    @ObservationIgnored private var lastHeartbeat = 0.0

    // Guest
    @ObservationIgnored private var lastQueueRev = -1
    @ObservationIgnored private var mirrored: [JfItem] = []
    @ObservationIgnored private var unavailable = Set<String>()
    @ObservationIgnored private var loadedTrackId: String?
    @ObservationIgnored private var pendingState: WfMessage?
    @ObservationIgnored private var skewSamples: [Double] = []
    @ObservationIgnored private var seekLagMs = 0.0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var lastResync = 0.0
    @ObservationIgnored private var lastWarning: String?
    @ObservationIgnored private var toldAboutHost = false
    /// Set while this session drives the player itself, so its own calls pass
    /// the transport gate that stops the guest's buttons.
    @ObservationIgnored private var applying = false
    /// Host-driven updates run one at a time: each can load a track, and
    /// overlapping ones fought over what the player should be playing.
    @ObservationIgnored private var chain: Task<Void, Never>?

    public init(client: JellyfinClient, player: PlaybackService) {
        self.client = client
        self.player = player
    }

    // MARK: - Starting and leaving

    public func create(relayBase: String, name: String, allowGuestAdds: Bool, allowGuestControl: Bool) async throws {
        guard let url = URL(string: base(relayBase) + "/create") else { throw failure("That relay address is not valid.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Created: Decodable { var code: String? }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let code = (try? JSONDecoder().decode(Created.self, from: data))?.code,
              let room = Waterfall.normalizedCode(code) else { throw failure("Could not create a room.") }
        guestAddsAllowed = allowGuestAdds
        guestControlAllowed = allowGuestControl
        try await open(room, relayBase: relayBase, name: name, as: .host)
        publishQueue()
        publishState()
    }

    public func join(code raw: String, relayBase: String, name: String) async throws {
        guard let room = Waterfall.normalizedCode(raw) else { throw failure("Room codes are 6 characters long.") }
        try await open(room, relayBase: relayBase, name: name, as: .guest)
    }

    /// `reason` becomes the notice when the room ended without being asked to.
    public func leave(reason: String? = nil) {
        receiveTask?.cancel()
        tickTask?.cancel()
        chain?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        receiveTask = nil
        tickTask = nil
        chain = nil
        socket = nil
        if role == .guest || player.transportGate != nil { player.transportGate = nil }
        code = nil
        role = nil
        memberId = nil
        roster = []
        queueRev = 0
        addedBy = []
        publishedQueue = []
        published = nil
        lastQueueRev = -1
        mirrored = []
        unavailable = []
        loadedTrackId = nil
        pendingState = nil
        skewSamples = []
        seekLagMs = 0
        lastResync = 0
        lastWarning = nil
        toldAboutHost = false
        guestAddsAllowed = true
        guestControlAllowed = false
        if let reason { notice = reason }
    }

    /// Host settings, republished at once so guests gain or lose them mid-room.
    public func setGuestPermissions(adds: Bool, control: Bool) {
        guard role == .host else { return }   // a guest's are the host's, mirrored
        guestAddsAllowed = adds
        guestControlAllowed = control
        publishQueue()
    }

    private func failure(_ message: String) -> Error { JellyfinError(status: 0, message: message) }

    private func base(_ relay: String) -> String {
        var b = relay.trimmingCharacters(in: .whitespaces)
        if b.isEmpty { b = Waterfall.defaultRelay }
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private struct Envelope: Decodable {
        var type: String
        var memberId: String?
        var roster: [Member]?
        var members: [Member]?
        var reason: String?
        var from: String?
        var payload: WfMessage?
    }

    private func open(_ room: String, relayBase: String, name: String, as role: Role) async throws {
        leave()
        struct Info: Decodable { var id: String? }
        serverId = (try? await client.get("/System/Info/Public", as: Info.self))?.id
        guard let url = Waterfall.roomSocketUrl(relayBase: base(relayBase), code: room, name: name) else {
            throw failure("That relay address is not valid.")
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        // The first message says whether we are in.
        let first: Envelope
        do {
            first = try decode(try await socket.receive())
        } catch {
            socket.cancel()
            throw failure("Could not reach the room server.")
        }
        guard first.type == "joined", let memberId = first.memberId else {
            socket.cancel()
            throw failure(first.reason == "room-full" ? "That room is full." : "No room with that code.")
        }
        self.socket = socket
        self.code = room
        self.role = role
        self.memberId = memberId
        self.roster = first.roster ?? []
        if role == .guest {
            player.transportGate = { [weak self] request in self?.gate(request) ?? false }
            send(helloMessage())
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func decode(_ message: URLSessionWebSocketTask.Message) throws -> Envelope {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let d): data = d
        @unknown default: throw failure("Unreadable message")
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            guard let message = try? await socket.receive() else {
                if !Task.isCancelled, self.socket === socket { leave(reason: "The room closed.") }
                return
            }
            guard let envelope = try? decode(message) else { continue }
            switch envelope.type {
            case "roster": roster = envelope.members ?? []
            case "relay":
                if let from = envelope.from, let payload = envelope.payload { onRelay(from, payload) }
            default: break
            }
        }
    }

    private func send(_ payload: WfMessage, to: String? = nil) {
        struct Out: Encodable { var type = "relay"; var to: String?; var payload: WfMessage }
        guard let socket, let data = try? JSONEncoder().encode(Out(to: to, payload: payload)),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func helloMessage() -> WfMessage { WfMessage(k: "hello", serverId: serverId) }

    private func onRelay(_ from: String, _ m: WfMessage) {
        // Someone on another Jellyfin server cannot stream the host's tracks.
        if Waterfall.isForeignServer(m.serverId, serverId) {
            if role == .host { send(WfMessage(k: "wrong-server"), to: from) }
            else { leave(reason: "That room is hosted on a different Jellyfin server.") }
            return
        }
        switch (m.k, role) {
        case ("hello", .host?):
            publishQueue(to: from)
            publishState(to: from)
        case ("wrong-server", _):
            leave(reason: "That room is hosted on a different Jellyfin server.")
        case ("enqueue", .host?):
            Task { await handleEnqueue(from, m) }
        case ("control", .host?):
            Task { await handleControl(m) }
        case ("enqueue-rejected", .guest?):
            notice = m.reason ?? "The host refused that addition."
        case ("queue", .guest?):
            serially { await self.applyQueue(m) }
        case ("state", .guest?):
            if let sentAt = m.sentAt, sentAt.isFinite {
                skewSamples.append(Waterfall.nowMs() - sentAt)
                if skewSamples.count > Waterfall.skewWindow { skewSamples.removeFirst() }
            }
            serially { await self.applyState(m) }
        default:
            break
        }
    }

    private func serially(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { await previous?.value; guard !Task.isCancelled else { return }; await work() }
    }

    private func tick() {
        guard isActive else { return }
        if role == .host { hostTick() }
    }

    // MARK: - Host

    /// Publishes a change as soon as it shows (a pause, a skip, a seek), and
    /// everything on the heartbeat. Polled rather than hooked into every
    /// transport path, so a new way of changing tracks is covered for free.
    private func hostTick() {
        let now = Waterfall.nowMs()
        if player.queueIds != publishedQueue { publishQueue() }
        guard let item = player.item else { return }
        let positionMs = player.livePositionSeconds * 1000
        var changed = true
        if let p = published, p.trackId == item.id, p.paused == player.isPaused, p.index == player.queue.index {
            let expected = p.positionMs + (p.paused ? 0 : now - p.at)
            changed = abs(positionMs - expected) > Waterfall.driftMs
        }
        if changed || now - lastHeartbeat >= Waterfall.heartbeatMs { publishState() }
    }

    private func publishState(to: String? = nil) {
        guard role == .host, let item = player.item else { return }
        let now = Waterfall.nowMs()
        let positionMs = (player.livePositionSeconds * 1000).rounded()
        send(Waterfall.state(serverId: serverId, trackId: item.id, positionMs: positionMs,
                             paused: player.isPaused, index: player.queue.index, now: now), to: to)
        published = (item.id, player.isPaused, player.queue.index, positionMs, now)
        if to == nil { lastHeartbeat = now }
    }

    private func publishQueue(to: String? = nil) {
        guard role == .host else { return }
        let ids = player.queueIds
        if to == nil, ids != publishedQueue || queueRev == 0 {
            queueRev += 1
        }
        addedBy = Waterfall.aligned(addedBy, to: ids.count)
        publishedQueue = ids
        send(Waterfall.queue(serverId: serverId, rev: queueRev, trackIds: ids, addedBy: addedBy,
                             index: player.queue.index, guestAddsAllowed: guestAddsAllowed,
                             guestControlAllowed: guestControlAllowed), to: to)
    }

    /// Checked with the host's own account: the room's premise is that
    /// everyone streams the same track, and a guest can see tracks the host
    /// cannot.
    private func handleEnqueue(_ from: String, _ m: WfMessage) async {
        guard guestAddsAllowed else {
            return send(Waterfall.enqueueRejected("The host has turned off guest additions."), to: from)
        }
        let ids = Array((m.trackIds ?? []).filter { !$0.isEmpty }.prefix(100))
        guard !ids.isEmpty else { return }
        let items = (try? await client.items(ids: ids)) ?? []
        guard !items.isEmpty else {
            return send(Waterfall.enqueueRejected("The host cannot access that track on this server."), to: from)
        }
        let name = roster.first { $0.id == from }?.name ?? "A guest"
        await player.addToQueue(items)
        addedBy = Waterfall.aligned(addedBy, to: player.queueIds.count - items.count) + items.map { _ in name }
        if items.count < ids.count {
            send(Waterfall.enqueueRejected("Some of those tracks are not available to the host."), to: from)
        }
        publishQueue()
        notice = "\(name) added \(items.count == 1 ? "a song" : "\(items.count) songs")."
    }

    /// Applied through the player's own transport, so everything a button
    /// does (reports, the queue, crossfade) happens exactly as if the host
    /// pressed it.
    private func handleControl(_ m: WfMessage) async {
        guard guestControlAllowed, let action = Waterfall.controlAction(m.action) else { return }
        switch action {
        case .playpause: player.togglePlayPause()
        case .next: await player.next()
        case .prev: await player.previous()
        case .seek:
            guard let ms = m.positionMs, ms.isFinite, ms >= 0,
                  player.durationSeconds <= 0 || ms / 1000 <= player.durationSeconds else { return }
            await player.seek(to: ms / 1000)
        }
        publishState()
    }

    // MARK: - Guest

    /// A guest's own buttons never drive its player, which would fork the
    /// room: they ask the host, when the host allows it, or say why not.
    private func gate(_ request: PlaybackService.TransportRequest) -> Bool {
        guard role == .guest, !applying else { return false }
        switch request {
        case .playPause: requestControl(.playpause)
        case .next: requestControl(.next)
        case .previous: requestControl(.prev)
        case .seek(let seconds): requestControl(.seek, positionMs: seconds * 1000)
        case .enqueue(let items):
            if guestAddsAllowed {
                send(Waterfall.enqueue(serverId: serverId, trackIds: items.map(\.id)))
                notice = "Asked the host to add \(items.count == 1 ? "it" : "them") to the queue."
            } else {
                notice = "The host has turned off adding to the queue."
            }
        case .replaceQueue:
            notice = "The host chooses what plays in this room. Leave the room to play something else."
        }
        return true
    }

    private func requestControl(_ action: Waterfall.ControlAction, positionMs: Double? = nil) {
        if guestControlAllowed {
            send(Waterfall.control(action, positionMs: positionMs))
        } else if !toldAboutHost {
            toldAboutHost = true
            notice = "The host controls playback in this room. Your play, skip and seek controls do nothing until you leave."
        }
    }

    private func requestResync() {
        let now = Waterfall.nowMs()
        guard now - lastResync >= Waterfall.heartbeatMs else { return }
        lastResync = now
        send(helloMessage())
    }

    private func warnOnce(_ message: String) {
        let key = "\(message):\(player.item?.id ?? "")"
        guard key != lastWarning else { return }
        lastWarning = key
        notice = message
    }

    private func applyQueue(_ m: WfMessage) async {
        guard let rev = m.rev, !Waterfall.isStaleQueue(rev, lastApplied: lastQueueRev) else { return }
        lastQueueRev = rev
        guestAddsAllowed = m.guestAddsAllowed != false
        guestControlAllowed = m.guestControlAllowed == true
        let ids = m.trackIds ?? []
        var known = Dictionary((mirrored + player.queue.items).filter { !unavailable.contains($0.id) }
            .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let missing = Waterfall.missingTrackIds(ids, known: Set(known.keys))
        if !missing.isEmpty {
            for start in stride(from: 0, to: missing.count, by: 100) {
                let chunk = Array(missing[start..<min(start + 100, missing.count)])
                for item in (try? await client.items(ids: chunk)) ?? [] { known[item.id] = item }
            }
        }
        // Placeholders, not gaps: per-user permissions apply to each member,
        // and dropping an entry would shift this queue out of line with the
        // host's for good.
        unavailable = []
        mirrored = ids.map { id in
            if let item = known[id] { return item }
            unavailable.insert(id)
            return JfItem(id: id, name: "Unavailable to you", type: "Audio")
        }
        if !unavailable.isEmpty { warnOnce("Some songs in this room are not available to your account.") }
        if let index = m.index, mirrored.indices.contains(index) {
            applying = true
            player.adoptQueue(mirrored, index: index)
            applying = false
        }
        // A state that raced ahead of this queue can go now.
        if let pending = pendingState {
            pendingState = nil
            await applyState(pending)
        }
    }

    private func applyState(_ s: WfMessage) async {
        guard let trackId = s.trackId else { return }
        var index = mirrored.firstIndex { $0.id == trackId }
        if let i = s.index, mirrored.indices.contains(i), mirrored[i].id == trackId { index = i }
        var justLoaded = false

        // Also when this player moved on by itself ahead of the host (its
        // track ended first): drift correction would seek the wrong song.
        if loadedTrackId != trackId || player.item?.id != trackId {
            if player.item?.id == trackId {
                // Already moved on to it by itself, at the end of the last one.
                loadedTrackId = trackId
            } else {
                guard let index else {
                    // Joining: the state often lands before the queue it needs.
                    pendingState = s
                    requestResync()
                    return
                }
                guard !unavailable.contains(trackId) else {
                    return warnOnce("You do not have access to the song playing in this room.")
                }
                applying = true
                await player.play(mirrored, startIndex: index)
                applying = false
                guard player.item?.id == trackId else { return }   // the next heartbeat retries
                loadedTrackId = trackId
                justLoaded = true
                await seekToHost(s)
            }
        }

        let expected = Waterfall.expectedPositionMs(s, offsetMs: Waterfall.clockOffsetMs(skewSamples))
        if !justLoaded, !seeking, player.durationSeconds > 0,
           Waterfall.shouldReseek(currentMs: player.livePositionSeconds * 1000, expectedMs: expected) {
            await seekToHost(s)
        }

        applying = true
        if s.paused == true, !player.isPaused {
            player.pause()
        } else if s.paused != true, player.isPaused {
            player.resume()
        }
        applying = false
    }

    /// Seeks to where the host will be once the seek has landed, leading by
    /// how long the last one took.
    private func seekToHost(_ s: WfMessage) async {
        let expected = Waterfall.expectedPositionMs(s, offsetMs: Waterfall.clockOffsetMs(skewSamples))
        let target = Waterfall.seekTargetMs(expectedMs: expected, lastSeekMs: seekLagMs, paused: s.paused == true)
        let started = ContinuousClock.now
        seeking = true
        applying = true
        await player.seek(to: target / 1000)
        applying = false
        seeking = false
        let took = started.duration(to: .now)
        seekLagMs = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        debugLog("waterfall: seeked to \(Int(target)) ms in \(Int(seekLagMs)) ms")
    }
}
