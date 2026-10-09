import Foundation
import Observation

/// Explicit marks from Cascade Server (the `explicit` capability): Jellyfin
/// has no flag of its own, so the plugin works one out per song and answers
/// from what it already knows, queueing the rest. Rows ask for their song as
/// they appear; the asks are gathered into one request per screenful.
@MainActor
@Observable
public final class ExplicitRatings {
    public private(set) var explicit: Set<String> = []
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var flushing: Task<Void, Never>?
    @ObservationIgnored private let client: JellyfinClient

    /// The plugin's limit per request.
    nonisolated static let batch = 500

    public init(client: JellyfinClient) { self.client = client }

    public func isExplicit(_ id: String) -> Bool { explicit.contains(id) }

    /// Asks about a song once per session. A song the plugin had no answer for
    /// is looked up on the server meanwhile and comes back marked next launch.
    /// ponytail: no re-ask within a session; add a timed retry if marks feel late.
    public func want(_ id: String) {
        guard asked.insert(id).inserted else { return }
        pending.append(id)
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            // A beat, so a screen's worth of rows goes as one request.
            try? await Task.sleep(for: .milliseconds(60))
            await self?.flush()
        }
    }

    private func flush() async {
        while !pending.isEmpty {
            let ids = Array(pending.prefix(Self.batch))
            pending.removeFirst(ids.count)
            struct Body: Encodable { var ids: [String] }
            struct Reply: Decodable { var items: [String: String]? }
            guard let reply: Reply = try? await client.post("/CascadeServer/Explicit/Query", body: Body(ids: ids)) else { continue }
            let marked = Self.explicitIds(reply.items ?? [:])
            if !marked.isEmpty { explicit.formUnion(marked) }
        }
        flushing = nil
    }

    nonisolated static func explicitIds(_ items: [String: String]) -> Set<String> {
        Set(items.compactMap { $0.value == "explicit" ? $0.key : nil })
    }
}
