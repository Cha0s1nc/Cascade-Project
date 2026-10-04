import SwiftUI
import CascadeKit

/// The three animated bars on the playing row, for any track list to put on a row. Nothing
/// is drawn for a row that is not the playing track. The bars follow the playing item's audio
/// level when a tap is attached (PlaybackService.tapLevel), otherwise a canned animation, which
/// is what the desktop does when it has no signal; paused, they hold still. A tap is never
/// attached just for this: it costs the gapless handover (apple/CODEMAP.md).
struct PlayingIndicator: View {
    let itemId: String
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let player = state.player, player.item?.id == itemId {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: player.isPaused || reduceMotion)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate, player: player)
            }
            .frame(width: 14, height: 14)
            .accessibilityLabel(player.isPaused ? "Paused" : "Playing")
        }
    }

    private func bars(at t: Double, player: PlaybackService) -> some View {
        let level = player.tapLevel.map(Double.init)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .frame(width: 3, height: 14 * height(i, t: t, level: level, still: player.isPaused || reduceMotion))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(Color.accentColor)
    }

    /// 0.2 to 1 of the full height. Each bar has its own speed and phase, so they never move in
    /// step; a real level scales how far they swing.
    private func height(_ bar: Int, t: Double, level: Double?, still: Bool) -> Double {
        if still { return 0.35 }
        let wave = abs(sin(t * (2.1 + 0.8 * Double(bar)) + Double(bar) * 1.7))
        guard let level else { return 0.2 + 0.8 * wave }
        return 0.2 + 0.8 * min(1, level * (0.55 + 0.45 * wave) * 1.4)
    }
}
