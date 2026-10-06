import Foundation
import Network
import CascadeKit

/// The Cha0s Stream control server (main.js ~263-325) on 127.0.0.1:47847. Parsing, routing and the
/// token file are CascadeKit's (ControlProtocol.swift, tested); this is the listener.
///
/// The Electron build may hold the port, and the token file belongs to Cha0s Stream: a taken port
/// or an unusable token just leaves the server off, quietly.
@MainActor
final class ControlServer {
    static let shared = ControlServer()
    private var listener: NWListener?
    private var token: String?
    private weak var state: AppState?

    func start(state: AppState) {
        guard listener == nil, let token = ControlToken.load() else { return }
        self.token = token
        self.state = state
        let params = NWParameters.tcp
        // Loopback only: a LAN peer must not even see the port.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ControlServerProtocol.port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in MainActor.assumeIsolated { self?.serve(c) } }
        l.stateUpdateHandler = { [weak self] s in
            // Address in use (the Electron build is running) lands here; nothing to do about it.
            if case .failed = s { MainActor.assumeIsolated { self?.listener?.cancel(); self?.listener = nil } }
        }
        listener = l
        l.start(queue: .main)
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        let box = BufferBox()
        // A client that never finishes its request does not get to hold the socket.
        let idle = Task { try? await Task.sleep(for: .seconds(10)); c.cancel() }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
                MainActor.assumeIsolated {
                    guard let self else { c.cancel(); return }
                    if let data { box.data.append(data) }
                    switch ControlServerProtocol.parse(box.data) {
                    case .request(let req):
                        idle.cancel()
                        self.reply(c, self.respond(to: req))
                    case .malformed:
                        idle.cancel()
                        self.reply(c, ControlResponse(status: 400, body: #"{"ok":false,"error":"Bad request"}"#))
                    case .incomplete:
                        if done || error != nil { idle.cancel(); c.cancel() } else { read() }
                    }
                }
            }
        }
        read()
    }

    private func reply(_ c: NWConnection, _ r: ControlResponse) {
        c.send(content: r.data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(to req: ControlRequest) -> ControlResponse {
        guard let token, let state else { return ControlResponse(status: 404, body: "") }
        let session = state.config.map { ControlContext.Session(url: $0.url, token: $0.token, userId: $0.userId) }
        let context = ControlContext(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            jellyfin: session, nowPlaying: MacIntegrations.nowPlayingSnapshot(state),
            perform: { action in Task { @MainActor in Self.shared.perform(action) } })
        return ControlServerProtocol.route(req, token: token, context: context)
    }

    private func perform(_ action: String) {
        guard let state else { return }
        // Same as the media keys: during a video, play/pause drives the video and track skips do nothing.
        if let v = state.videoSession {
            if action == "playpause" { v.togglePlayPause() }
            return
        }
        guard let p = state.player else { return }
        switch action {
        case "playpause": p.togglePlayPause()
        case "next": Task { await p.next() }
        case "prev": Task { await p.previous() }
        default: break
        }
    }
}

/// A request's bytes so far; only touched on the main queue.
private final class BufferBox: @unchecked Sendable { var data = Data() }
