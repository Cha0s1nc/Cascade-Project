import SwiftUI
import CascadeKit

/// "Pick up where you left off?" in the window's corner after sign-in: the
/// last session's queue, paused, only if the person wants it. It goes away by
/// itself after 20 seconds, and a song started meanwhile wins (the offer's
/// accept checks that nothing is playing). Ignoring it keeps the saved queue,
/// so the next launch asks again.
struct RestoreQueueCard: View {
    @Environment(AppState.self) private var state
    let offer: AppState.RestoreOffer

    static let lifetime: Double = 20
    @State private var started = Date()

    private var current: JfItem? {
        offer.queue.queue.indices.contains(offer.queue.index) ? offer.queue.queue[offer.queue.index] : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: current?.albumId ?? current?.id, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off?").font(.callout.weight(.semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                // The time left, as a bar that runs out.
                TimelineView(.animation(minimumInterval: 0.25)) { context in
                    let left = max(0, 1 - context.date.timeIntervalSince(started) / Self.lifetime)
                    GeometryReader { geo in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.accentColor).frame(width: geo.size.width * left)
                            }
                    }
                    .frame(height: 3)
                }
                .padding(.top, 4)
            }
            .frame(width: 220, alignment: .leading)
            Button("Restore") {
                offer.accept()
                close()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Button { close() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.hover)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .task(id: offer.id) {
            started = Date()
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard !Task.isCancelled else { return }
            close()
        }
    }

    private var summary: String {
        let count = offer.queue.queue.count
        let songs = count == 1 ? "1 song" : "\(count) songs"
        guard let current else { return songs }
        let artist = current.albumArtist ?? current.artists?.first
        return [current.name, artist].compactMap { $0 }.joined(separator: " - ") + " \u{00B7} " + songs
    }

    private func close() {
        guard state.restoreOffer?.id == offer.id else { return }
        withAnimation(.easeInOut(duration: 0.25)) { state.restoreOffer = nil }
    }
}
